#!/usr/bin/env bash

set -eo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ ! -f "${DIR}/.env" ]; then
    echo "Missing ${DIR}/.env configuration file."
    exit 1;
fi

set -a
source "${DIR}/.env"
set -a

# Name of the node-pools for Gitpod services and workspaces
SERVICES_POOL="services"
WORKSPACES_POOL="workspaces"

K8S_NODE_VM_SIZE=${K8S_NODE_VM_SIZE:="Standard_DS3_v2"}
CERT_NAME="https-certificates"
MYSQL_GITPOD_ENCRYPTION_KEY='[{"name":"general","version":1,"primary":true,"material":"4uGh1q8y2DYryJwrVMHs0kWXJlqvHWWt/KJuNi04edI="}]'

# Secrets
SECRET_DATABASE="az-sql-token"
SECRET_REGISTRY="az-registry-token"
SECRET_STORAGE="az-storage-token"

function check_prerequisites() {
    if [ -z "${AZURE_SUBSCRIPTION_ID}" ]; then
        echo "Missing AZURE_SUBSCRIPTION_ID environment variable."
        exit 1;
    fi

    if [ -z "${AZURE_TENANT_ID}" ]; then
        echo "Missing AZURE_TENANT_ID environment variable."
        exit 1;
    fi

    if [ -z "${RESOURCE_GROUP}" ]; then
        echo "Missing RESOURCE_GROUP environment variable."
        exit 1;
    fi

    if [ -z "${CLUSTER_NAME}" ]; then
        echo "Missing CLUSTER_NAME environment variable."
        exit 1;
    fi

    if [ -z "${DOMAIN}" ]; then
        echo "Missing DOMAIN environment variable."
        exit 1;
    fi

    if [ -z "${LOCATION}" ]; then
        echo "Missing LOCATION environment variable."
        exit 1;
    fi

    if [ -z "${REGISTRY_NAME}" ]; then
        echo "Missing REGISTRY_NAME environment variable."
        exit 1;
    fi
}

function install() {
    echo "Gitpod installer version: $(gitpod-installer version | jq -r '.version')"

    check_prerequisites

    echo "Updating helm repositories..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    echo "Installing..."

    login

    # Everything will be installed to this resource group
    if [ "$(az group show --name ${RESOURCE_GROUP} --query "name == '${RESOURCE_GROUP}'" || echo "empty")" == "true" ]; then
      echo "Resource group exists..."
    else
      az group create \
        --location "${LOCATION}" \
        --name "${RESOURCE_GROUP}"
    fi

    if [ "$(az aks show --name ${CLUSTER_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${CLUSTER_NAME}'" || echo "empty")" == "true" ]; then
      echo "Kubernetes cluster exists..."
    else
      if [ -z "${AKS_VERSION}" ]; then
        echo "Finding Kubernetes version"
        AKS_VERSION=$(az aks get-versions \
          --location northeurope \
          --query "orchestrators[?contains(orchestratorVersion, '1.21.')].orchestratorVersion" \
          -o json | jq -r '.[-1]')
      fi

      echo "Creating Kubernetes instance with v${AKS_VERSION}..."
      az aks create \
        --enable-cluster-autoscaler \
        --enable-managed-identity \
        --location "${LOCATION}" \
        --kubernetes-version "${AKS_VERSION}" \
        --max-count "50" \
        --max-pods "110" \
        --min-count "3" \
        --name "${CLUSTER_NAME}" \
        --node-osdisk-size "100" \
        --node-vm-size "${K8S_NODE_VM_SIZE}" \
        --nodepool-labels gitpod.io/workload_meta=true gitpod.io/workload_ide=true \
        --nodepool-name "${SERVICES_POOL}" \
        --resource-group "${RESOURCE_GROUP}" \
        --no-ssh-key \
        --vm-set-type "VirtualMachineScaleSets"
    fi

    if [ "$(az aks nodepool show --cluster-name ${CLUSTER_NAME} --name ${WORKSPACES_POOL} --resource-group ${RESOURCE_GROUP} --query "name == '${WORKSPACES_POOL}'" || echo "empty")" == "true" ]; then
      echo "Node pool ${WORKSPACES_POOL} exists..."
    else
      echo "Creating ${WORKSPACES_POOL} node pool..."

      az aks nodepool add \
        --cluster-name "${CLUSTER_NAME}" \
        --enable-cluster-autoscaler \
        --kubernetes-version "${AKS_VERSION}" \
        --labels gitpod.io/workload_workspace_services=true gitpod.io/workload_workspace_regular=true gitpod.io/workload_workspace_headless=true \
        --max-count "50" \
        --max-pods "110" \
        --min-count "3" \
        --name "${WORKSPACES_POOL}" \
        --node-osdisk-size "100" \
        --node-vm-size "${K8S_NODE_VM_SIZE}" \
        --resource-group "${RESOURCE_GROUP}"
      fi

    setup_kubectl

    # Create secret with container registry credentials
    if [ -n "${IMAGE_PULL_SECRET_FILE}" ] && [ -f "${IMAGE_PULL_SECRET_FILE}" ]; then
        if ! kubectl get secret gitpod-image-pull-secret; then
            kubectl create secret generic gitpod-image-pull-secret \
                --from-file=.dockerconfigjson="${IMAGE_PULL_SECRET_FILE}" \
                --type=kubernetes.io/dockerconfigjson  >/dev/null 2>&1 || true
        fi
    fi

    install_cert_manager
    setup_container_registry
    setup_managed_dns
    setup_mysql_database
    setup_storage
    install_gitpod

    cat << EOF
==========================
Gitpod is now installed on your cluster

Please update your DNS records with the relevant nameserver.
EOF
}

function install_cert_manager() {
  echo "Installing cert-manager..."
  helm upgrade \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace='cert-manager' \
    --reset-values \
    --set installCRDs=true \
    --set 'extraArgs={--dns01-recursive-nameservers-only=true,--dns01-recursive-nameservers=8.8.8.8:53\,1.1.1.1:53}' \
    --wait \
    cert-manager \
    jetstack/cert-manager

  # ensure cert-manager and CRDs are installed and running
  kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
}

function install_gitpod() {
  echo "Installing Gitpod..."

  local CONFIG_FILE="${DIR}/gitpod-config.yaml"

  gitpod-installer init > "${CONFIG_FILE}"

  echo "Updating config..."

  yq e -i ".certificate.name = \"${CERT_NAME}\"" "${CONFIG_FILE}"
  yq e -i ".containerRegistry.inCluster = false" "${CONFIG_FILE}"
  yq e -i ".containerRegistry.external.url = \"${DOCKER_REGISTRY_SERVER}\"" "${CONFIG_FILE}"
  yq e -i ".containerRegistry.external.certificate.kind = \"secret\"" "${CONFIG_FILE}"
  yq e -i ".containerRegistry.external.certificate.name = \"${SECRET_REGISTRY}\"" "${CONFIG_FILE}"
  yq e -i ".database.inCluster = false" "${CONFIG_FILE}"
  yq e -i ".database.external.certificate.kind = \"secret\"" "${CONFIG_FILE}"
  yq e -i ".database.external.certificate.name = \"${SECRET_DATABASE}\"" "${CONFIG_FILE}"
  yq e -i ".domain = \"${DOMAIN}\"" "${CONFIG_FILE}"
  yq e -i ".metadata.region = \"${LOCATION}\"" "${CONFIG_FILE}"
  yq e -i ".objectStorage.inCluster = false" "${CONFIG_FILE}"
  yq e -i ".objectStorage.azure.credentials.kind = \"secret\"" "${CONFIG_FILE}"
  yq e -i ".objectStorage.azure.credentials.name = \"${SECRET_STORAGE}\"" "${CONFIG_FILE}"
  yq e -i '.workspace.runtime.containerdRuntimeDir = "/var/lib/containerd/io.containerd.runtime.v2.task/k8s.io"' "${CONFIG_FILE}"

  gitpod-installer \
    render \
    --config="${CONFIG_FILE}" > gitpod.yaml

  kubectl apply -f gitpod.yaml
}

function install_jaeger_operator(){
  echo "Installing Jaeger operator..."
  kubectl apply -f https://raw.githubusercontent.com/jaegertracing/helm-charts/main/charts/jaeger-operator/crds/crd.yaml
  helm upgrade \
    --atomic \
    --cleanup-on-fail \
    --create-namespace \
    --install \
    --namespace='jaeger-operator' \
    --reset-values \
    --set installCRDs=true \
    --set crd.install=false \
    --values "${DIR}/charts/assets/jaeger-values.yaml" \
    --wait \
    jaegeroperator \
    jaegertracing/jaeger-operator

  kubectl apply -f "${DIR}/charts/assets/jaeger-gitpod.yaml"
}

function login() {
  echo "Log into Azure..."
  az login

  echo "Set Azure subscription..."
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
}

function setup_container_registry() {
  if [ "$(az acr show --name ${REGISTRY_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${REGISTRY_NAME}'" || echo "empty")" == "true" ]; then
    echo "Registry exists..."
  else
    echo "Setup Azure Container Registry..."
    az acr create \
      --admin-enabled true \
      --location "${LOCATION}" \
      --name "${REGISTRY_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --sku Premium
  fi

  DOCKER_USER=$(az acr credential show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query username \
    --resource-group "${RESOURCE_GROUP}")

  export DOCKER_REGISTRY_SERVER=$(az acr show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query loginServer \
    --resource-group "${RESOURCE_GROUP}")

  DOCKER_PASSWORD=$(az acr credential show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query passwords[0].value \
    --resource-group "${RESOURCE_GROUP}")

  echo "Create registry secret..."
  kubectl create secret docker-registry "${SECRET_REGISTRY}" \
    --docker-server="${DOCKER_REGISTRY_SERVER}" \
    --docker-username="${DOCKER_USER}" \
    --docker-password="${DOCKER_PASSWORD}" \
    --dry-run=client -o yaml | \
    kubectl replace --force -f -
}

function setup_kubectl() {
  echo "Get Kubernetes credentials..."
  az aks get-credentials \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --overwrite-existing
}

function setup_managed_dns() {
  if [ -n "${SETUP_MANAGED_DNS}" ] && [ "${SETUP_MANAGED_DNS}" == "true" ]; then
    echo "Installing managed DNS..."

    if [ "$(az network dns zone show --name ${DOMAIN} --resource-group ${RESOURCE_GROUP} --query "name == '${DOMAIN}'" || echo "empty")" == "true" ]; then
      echo "Using existing managed DNS zone ${DOMAIN}..."
    else
      echo "Creating managed DNS zone for domain ${DOMAIN}..."
      az network dns zone create \
        --name "${DOMAIN}" \
        --resource-group "${RESOURCE_GROUP}"
    fi

    echo "Allow Kubernetes managed identity to make DNS changes..."
    ZONE_ID=$(az network dns zone show --name "${DOMAIN}" --resource-group "${RESOURCE_GROUP}" --query "id" -o tsv)

    KUBELET_OBJECT_ID=$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "identityProfile.kubeletidentity.objectId" -o tsv)
    KUBELET_CLIENT_ID=$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "identityProfile.kubeletidentity.clientId" -o tsv)

    az role assignment create \
      --assignee "${KUBELET_OBJECT_ID}" \
      --role "DNS Zone Contributor" \
      --scope "${ZONE_ID}"

    # Use v5.4.8 as external-dns v0.10.x has issue using Azure managed identities not in v0.9.0
    # @link https://github.com/kubernetes-sigs/external-dns/issues/2383
    helm upgrade \
      --atomic \
      --cleanup-on-fail \
      --create-namespace \
      --install \
      --namespace external-dns \
      --reset-values \
      --set provider=azure \
      --set azure.resourceGroup="${RESOURCE_GROUP}" \
      --set azure.subscriptionId="${AZURE_SUBSCRIPTION_ID}" \
      --set azure.tenantId="${AZURE_TENANT_ID}" \
      --set azure.useManagedIdentityExtension=true \
      --set azure.userAssignedIdentityID="${KUBELET_CLIENT_ID}" \
      --set logFormat=json \
      --version=5.4.8 \
      --wait \
      external-dns \
      bitnami/external-dns

    echo "Installing cert-manager certificate issuer..."
    envsubst < "${DIR}/charts/assets/issuer.yaml" | kubectl apply -f -
  fi
}

function setup_mysql_database() {
  MYSQL_GITPOD_USERNAME="gitpod"
  MYSQL_GITPOD_PASSWORD=$(openssl rand -base64 20)

  if [ "$(az mysql server show --name ${MYSQL_INSTANCE_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${MYSQL_INSTANCE_NAME}'" || echo "empty")" == "true" ]; then
    echo "MySQL instance exists - updating password..."
    az mysql server update \
      --admin-password "${MYSQL_GITPOD_PASSWORD}" \
      --name "${MYSQL_INSTANCE_NAME}" \
      --resource-group "${RESOURCE_GROUP}"
  else
    echo "Creating MySQL instance..."
    az mysql server create \
      --admin-user "${MYSQL_GITPOD_USERNAME}" \
      --admin-password "${MYSQL_GITPOD_PASSWORD}" \
      --auto-grow Enabled \
      --location "${LOCATION}" \
      --name "${MYSQL_INSTANCE_NAME}" \
      --public Disabled \
      --resource-group "${RESOURCE_GROUP}" \
      --sku-name GP_Gen5_2 \
      --ssl-enforcement Disabled \
      --storage-size 20480 \
      --version "5.7"
  fi

  DB_NAME=gitpod
  if [ "$(az mysql db show --name ${DB_NAME} --resource-group ${RESOURCE_GROUP} --server-name ${MYSQL_INSTANCE_NAME} --query "name == '${DB_NAME}'" || echo "empty")" == "true" ]; then
    echo "Gitpod MySQL database exists..."
  else
    echo "Creating Gitpod MySQL database..."
    az mysql db create \
      --name "${DB_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --server-name "${MYSQL_INSTANCE_NAME}"
  fi

  MANAGED_RG="MC_${RESOURCE_GROUP}_${CLUSTER_NAME}_${LOCATION}"
  DEFAULT_VNET_NAME=$(az resource list -g ${MANAGED_RG} --namespace "Microsoft.Network" --resource-type "virtualNetworks" | jq -r '.[].name')
  DEFAULT_VNET_SUBNET=$(az network vnet subnet list -g ${MANAGED_RG} --vnet-name ${DEFAULT_VNET_NAME} | jq -r '.[].name')

  # @link: https://docs.microsoft.com/en-us/azure/mysql/concepts-data-access-security-private-link
  # create private endpoint for mysql server to connect. 
  echo "Create Private Endpoint for Mysql Server"
  if [ "$(az network private-endpoint show --resource-group ${RESOURCE_GROUP} --name private-endpoint --query "name == 'private-endpoint'" || echo "empty")" == "true" ]; then
      echo "Private Endpoint exists..."
  else
      echo "Query Mysql Id"
      export MYSQL_RESOURCE_ID=$(az mysql server show --resource-group ${RESOURCE_GROUP}  --name ${MYSQL_INSTANCE_NAME} --query id --output tsv)
      echo "${MYSQL_RESOURCE_ID}"
  
      echo "Create Private Endpoint for Mysql Server Now..."
      az network private-endpoint create -g ${RESOURCE_GROUP} -n private-endpoint --vnet-name "${DEFAULT_VNET_NAME}" \
         --subnet "${DEFAULT_VNET_SUBNET}" \
         --private-connection-resource-id "${MYSQL_RESOURCE_ID}" \
         --connection-name private-endpoint \
         --group-id "mysqlServer" \
         -l ${LOCATION}
  fi
  
  echo "Create Private DNS Zone for Private Endpoint"
  if [ "$(az network private-dns zone show --resource-group ${RESOURCE_GROUP} --name mysql.database.azure.com --query "name == 'mysql.database.azure.com'" || echo "empty")" == "true" ]; then
      echo "Private DNS Zone exists..."
  else
     az network private-dns zone create \
         --resource-group ${RESOURCE_GROUP} \
         --name "mysql.database.azure.com"
  fi
  
  echo "Create Private DNS link"
  if [ "$(az network private-dns link vnet show --resource-group ${RESOURCE_GROUP} --zone-name mysql.database.azure.com --name mysqllink --query "name == 'mysqllink'" || echo "empty")" == "true" ]; then
      echo "Private DNS link exists..."
  else
      az network private-dns link vnet create \
          --resource-group ${RESOURCE_GROUP}\
          --zone-name "mysql.database.azure.com" \
          --name "mysqllink" \
          --virtual-network "${DEFAULT_VNET_NAME}" \
          --registration-enabled false
  fi
  
  echo "Create Private DNS Zone Group"
  if [ "$(az network private-endpoint dns-zone-group show --endpoint-name private-endpoint --resource-group ${RESOURCE_GROUP} --name sqlzonegroup --query "name == 'sqlzonegroup'" || echo "empty")" == "true" ]; then
      echo "Private DNS Zone Group exists..."
  else
      az network private-endpoint dns-zone-group create \
         --resource-group ${RESOURCE_GROUP} \
         --endpoint-name "private-endpoint" \
         --name "sqlzonegroup" \
         --private-dns-zone "mysql.database.azure.com" \
         --zone-name sql
  fi

  echo "Create database secret..."
  kubectl create secret generic "${SECRET_DATABASE}" \
    --from-literal=encryptionKeys="${MYSQL_GITPOD_ENCRYPTION_KEY}" \
    --from-literal=host="${MYSQL_INSTANCE_NAME}.mysql.database.azure.com" \
    --from-literal=password="${MYSQL_GITPOD_PASSWORD}" \
    --from-literal=port="3306" \
    --from-literal=username="${MYSQL_GITPOD_USERNAME}@${MYSQL_INSTANCE_NAME}" \
    --dry-run=client -o yaml | \
    kubectl replace --force -f -
}

function setup_storage() {
  if [ "$(az storage account show --name ${STORAGE_ACCOUNT_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${STORAGE_ACCOUNT_NAME}'" || echo "empty")" == "true" ]; then
    echo "Storage account exists..."
  else
    echo "Create storage account..."
    az storage account create \
      --access-tier Hot \
      --kind StorageV2 \
      --location "${LOCATION}" \
      --name "${STORAGE_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --sku Standard_LRS
  fi

  PRINCIPAL_ID=$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "identityProfile.kubeletidentity.objectId" -o tsv)
  STORAGE_ACCOUNT_ID=$(az storage account show \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --output tsv \
    --query id \
    --resource-group "${RESOURCE_GROUP}" )

  echo "Allow Kubernetes managed identity to access the storage account..."
  az role assignment create \
    --assignee "${PRINCIPAL_ID}" \
    --role "Storage Blob Data Contributor" \
    --scope "${STORAGE_ACCOUNT_ID}"

  STORAGE_ACCOUNT_KEY=$(az storage account keys list \
      --account-name "${STORAGE_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --output json \
        | jq -r '.[] | select(.keyName == "key1") | .value')

  echo "Create storage secret..."
  kubectl create secret generic "${SECRET_STORAGE}" \
      --from-literal=accountName="${STORAGE_ACCOUNT_NAME}" \
      --from-literal=accountKey="${STORAGE_ACCOUNT_KEY}" \
      --dry-run=client -o yaml | \
      kubectl replace --force -f -
}

function uninstall() {
  check_prerequisites

  read -p "Are you sure you want to delete: Gitpod (y/n)? " -n 1 -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    set +e

    login
    setup_kubectl

    helm uninstall gitpod

    kubectl delete secret gitpod-image-pull-secret
    kubectl delete secret image-builder-registry-secret

    # Ensure we remove the load balancer
    kubectl delete service proxy

    echo "Deleting Kubernetes cluster..."
    az aks delete \
      --name "${CLUSTER_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --yes

    printf "\n%s\n" "Please make sure to delete the resource group ${RESOURCE_GROUP} and services:"
    printf "%s\n" "- https://portal.azure.com/#resource/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/overview"
  fi
}

function main() {
  case $1 in
    '--install')
      install
    ;;
    '--uninstall')
      uninstall
    ;;
    *)
      echo "Unknown command: $1"
      echo "Usage: $0 [--install|--uninstall]"
    ;;
  esac
  echo "Done"
}

main "$@"
