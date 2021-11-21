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

AKS_VERSION=${AKS_VERSION:="1.21.6"}
K8S_NODE_VM_SIZE=${K8S_NODE_VM_SIZE:="Standard_DS3_v2"}
GITPOD_VERSION=${GITPOD_VERSION:="0.10.0"}

function auth() {
    AUTHPROVIDERS_CONFIG=${1:="auth-providers-patch.yaml"}
    if [ ! -f "${AUTHPROVIDERS_CONFIG}" ]; then
        echo "The auth provider configuration file ${AUTHPROVIDERS_CONFIG} does not exist."
        exit 1
    fi

    login
    setup_kubectl

    echo "Using the auth providers configuration file: ${AUTHPROVIDERS_CONFIG}"
    # Patching the configuration with the user auth provider/s
    kubectl patch configmap auth-providers-config --type merge --patch "$(cat ${AUTHPROVIDERS_CONFIG})"
    # Restart the server component
    kubectl rollout restart deployment/server
}

function check_prerequisites() {
    if [ -z "${AZURE_SUBSCRIPTION_ID}" ]; then
        echo "Missing AZURE_SUBSCRIPTION_ID environment variable."
        exit 1;
    fi

    if [ -z "${AZURE_TENANT_ID}" ]; then
        echo "Missing AZURE_TENANT_ID environment variable."
        exit 1;
    fi

    if [ -z "${AZURE_CLIENT_ID}" ]; then
        echo "Missing AZURE_CLIENT_ID environment variable."
        exit 1;
    fi

    if [ -z "${AZURE_CLIENT_SECRET}" ]; then
        echo "Missing AZURE_CLIENT_SECRET environment variable."
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
    check_prerequisites

    echo "Updating helm repositories..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo add gitpod https://charts.gitpod.io
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
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
      echo "Creating Kubernetes instance..."
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
        --nodepool-labels "gitpod.io/workload_services=true" \
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
        --labels "gitpod.io/workload_workspaces=true" \
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
    install_jaeger_operator
    install_gitpod
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

  envsubst < "${DIR}/charts/assets/gitpod-values.yaml" | helm upgrade --install gitpod gitpod/gitpod -f -

  echo "Create certificate..."

  cat <<EOF > gitpod-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gitpod-certificate
  namespace: default
spec:
  secretName: proxy-config-certificates
  issuerRef:
    name: azure-issuer
    kind: ClusterIssuer
  dnsNames:
    - $DOMAIN
    - '*.$DOMAIN'
    - '*.ws.$DOMAIN'
EOF

  kubectl apply -f gitpod-certificate.yaml
  rm gitpod-certificate.yaml

  kubectl rollout restart deployment/server

  echo "Gitpod successfully installed to ${DOMAIN}..."
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
  echo "Log into Azure with Service Principal..."
  az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" > /dev/null 2>&1

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

  kubectl create secret docker-registry image-builder-registry-secret \
    --docker-server="${DOCKER_REGISTRY_SERVER}" \
    --docker-username="${DOCKER_USER}" \
    --docker-password="${DOCKER_PASSWORD}" \
    --dry-run=client -o yaml | \
    kubectl replace -n "${namespace}" --force -f -
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
    PRINCIPAL_ID=$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "identityProfile.kubeletidentity.objectId" -o tsv)
    ZONE_ID=$(az network dns zone show --name "${DOMAIN}" --resource-group "${RESOURCE_GROUP}" --query "id" -o tsv)

    # The Service Principal needs "Group Administrator" role
    # @link https://www.simonemms.com/blog/2021/01/10/setting-terraform-service-principal-to-work-with-azure-active-directory
    az role assignment create \
      --assignee "${PRINCIPAL_ID}" \
      --role "DNS Zone Contributor" \
      --scope "${ZONE_ID}"

    helm upgrade \
      --atomic \
      --cleanup-on-fail \
      --create-namespace \
      --install \
      --namespace external-dns \
      --reset-values \
      --set provider=azure \
      --set azure.resourceGroup="${RESOURCE_GROUP}" \
      --set azure.aadClientId="${AZURE_CLIENT_ID}" \
      --set azure.aadClientSecret="${AZURE_CLIENT_SECRET}" \
      --set azure.subscriptionId="${AZURE_SUBSCRIPTION_ID}" \
      --set azure.tenantId="${AZURE_TENANT_ID}" \
      --set logFormat=json \
      --wait \
      external-dns \
      bitnami/external-dns

    echo "Installing cert-manager certificate issuer..."
    envsubst < "${DIR}/charts/assets/issuer.yaml" | kubectl apply -f -
  fi
}

# @todo allow Gitpod to work with external Azure DB https://github.com/gitpod-io/gitpod/issues/5508
function setup_mysql_database() {
  export MYSQL_GITPOD_PASSWORD=$(openssl rand -base64 20)

  # if [ "$(az mysql server show --name ${MYSQL_INSTANCE_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${MYSQL_INSTANCE_NAME}'" || echo "empty")" == "true" ]; then
  #   echo "MySQL instance exists - updating password..."
  #   az mysql server update \
  #     --admin-password "${MYSQL_GITPOD_PASSWORD}" \
  #     --name "${MYSQL_INSTANCE_NAME}" \
  #     --resource-group "${RESOURCE_GROUP}"
  # else
  #   echo "Creating MySQL instance..."
  #   az mysql server create \
  #     --admin-user gitpod \
  #     --admin-password "${MYSQL_GITPOD_PASSWORD}" \
  #     --auto-grow Enabled \
  #     --name "${MYSQL_INSTANCE_NAME}" \
  #     --public Enabled \
  #     --resource-group "${RESOURCE_GROUP}" \
  #     --sku-name GP_Gen5_2 \
  #     --ssl-enforcement Disabled \
  #     --storage-size 20480 \
  #     --version "5.7"

  #   echo "Creating MySQL replica..."
  #   az mysql server replica create \
  #     --name "${MYSQL_INSTANCE_NAME}-replica" \
  #     --source-server "${MYSQL_INSTANCE_NAME}" \
  #     --resource-group "${RESOURCE_GROUP}"
  # fi

  # DB_NAME=gitpod
  # if [ "$(az mysql db show --name ${DB_NAME} --resource-group ${RESOURCE_GROUP} --server-name ${MYSQL_INSTANCE_NAME} --query "name == '${DB_NAME}'" || echo "empty")" == "true" ]; then
  #   echo "Gitpod MySQL database exists..."
  # else
  #   echo "Creating Gitpod MySQL database..."
  #   az mysql db create \
  #     --name "${DB_NAME}" \
  #     --resource-group "${RESOURCE_GROUP}" \
  #     --server-name "${MYSQL_INSTANCE_NAME}"
  # fi

  # echo "Allow Azure resources to access MySQL database..."
  # az mysql server firewall-rule create \
  #   --end-ip-address "0.0.0.0" \
  #   --name "Azure_Resources" \
  #   --resource-group "${RESOURCE_GROUP}" \
  #   --server-name "${MYSQL_INSTANCE_NAME}" \
  #   --start-ip-address "0.0.0.0"
}

function setup_storage() {
  if [ "$(az storage account show --name ${STORAGE_ACCOUNT_NAME} --resource-group ${RESOURCE_GROUP} --query "name == '${STORAGE_ACCOUNT_NAME}'" || echo "empty")" == "true" ]; then
    echo "Storage account exists..."
  else
    echo "Create storage account..."
    az storage account create \
      --access-tier Hot \
      --kind StorageV2 \
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

  export STORAGE_ACCOUNT_KEY=$(az storage account keys list \
      --account-name "${STORAGE_ACCOUNT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --output json \
        | jq -r '.[] | select(.keyName == "key1") | .value')
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
    '--auth')
      auth "auth-providers-patch.yaml"
    ;;
    '--install')
      install
    ;;
    '--uninstall')
      uninstall
    ;;
    *)
      echo "Unknown command: $1"
      echo "Usage: $0 [--install|--uninstall|--auth]"
    ;;
  esac
  echo "Done"
}

main "$@"
