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

K8S_NODE_VM_SIZE=${K8S_NODE_VM_SIZE:="Standard_D4_v3"}

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
        --min-count "1" \
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
        --min-count "1" \
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
    output_config
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
}

function output_config() {
  DOCKER_USER=$(az acr credential show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query username \
    --resource-group "${RESOURCE_GROUP}")

  DOCKER_REGISTRY_SERVER=$(az acr show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query loginServer \
    --resource-group "${RESOURCE_GROUP}")

  DOCKER_PASSWORD=$(az acr credential show \
    --name "${REGISTRY_NAME}" \
    --output tsv \
    --query passwords[0].value \
    --resource-group "${RESOURCE_GROUP}")

  STORAGE_ACCOUNT_KEY=$(az storage account keys list \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --output json \
      | jq -r '.[] | select(.keyName == "key1") | .value')

  cat << EOF


==========================
🎉🥳🔥🧡🚀

Your cloud infrastructure is ready to install Gitpod. Please visit
https://www.gitpod.io/docs/self-hosted/latest/getting-started#step-4-install-gitpod
for your next steps.

Passwords may change on subsequents runs of this guide.

=================
Config Parameters
=================

Domain Name: ${DOMAIN}

Registry
========
URL: ${DOCKER_REGISTRY_SERVER}
Registry Server: <blank>
Username: ${DOCKER_USER}
Password: ${DOCKER_PASSWORD}

Database
========
Host: ${MYSQL_INSTANCE_NAME}.mysql.database.azure.com
Username: ${MYSQL_GITPOD_USERNAME}@${MYSQL_INSTANCE_NAME}
Password: ${MYSQL_GITPOD_PASSWORD}
Port: 3306

Storage
=======
Region: ${LOCATION}
Account Name: ${STORAGE_ACCOUNT_NAME}
Access Key: ${STORAGE_ACCOUNT_KEY}

TLS Certificates
================
Issuer name: gitpod-issuer
Issuer type: Cluster issuer

EOF

  if [ -n "${SETUP_MANAGED_DNS}" ] && [ "${SETUP_MANAGED_DNS}" == "true" ]; then
  cat << EOF
===========
DNS Records
===========

Domain Name: ${DOMAIN}
Nameserver(s):
$(az network dns zone show --name ${DOMAIN} --resource-group ${RESOURCE_GROUP} --query "nameServers" -o tsv)
EOF
fi
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
      --wait \
      external-dns \
      bitnami/external-dns

    echo "Installing cert-manager certificate issuer..."
    envsubst < "${DIR}/charts/assets/issuer.yaml" | kubectl apply -f -
  fi
}

function setup_mysql_database() {
  MYSQL_GITPOD_USERNAME="gitpod"
  export MYSQL_GITPOD_PASSWORD=$(openssl rand -base64 20)

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
      --public Enabled \
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

  echo "Allow Azure resources to access MySQL database..."
  az mysql server firewall-rule create \
    --end-ip-address "0.0.0.0" \
    --name "Azure_Resources" \
    --resource-group "${RESOURCE_GROUP}" \
    --server-name "${MYSQL_INSTANCE_NAME}" \
    --start-ip-address "0.0.0.0"
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
