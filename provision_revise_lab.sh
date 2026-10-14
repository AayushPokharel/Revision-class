#!/usr/bin/env bash
# Provision the Azure resources for the 3-hour DevOps revision class.
# Existing resource group required: rg-lab-revise
# Defaults to eastus; override with LOCATION=westus2, for example.
set -Eeuo pipefail

RG="rg-lab-revise"
LOCATION="${LOCATION:-eastus}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
TOOLS_VM_SIZE="${TOOLS_VM_SIZE:-Standard_B2ms}"
APP_VM_SIZE="${APP_VM_SIZE:-Standard_B2s}"
AKS_NODE_SIZE="${AKS_NODE_SIZE:-Standard_B2s}"
ENV_FILE="${ENV_FILE:-.revise-lab.env}"

for bin in az ssh-keygen openssl curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: required command not found: $bin" >&2; exit 1; }
done

az account show >/dev/null 2>&1 || { echo "Please sign in to Azure first with: az login" >&2; exit 1; }
az group show --name "$RG" >/dev/null 2>&1 || { echo "Resource group '$RG' was not found in the active subscription. Check: az account show" >&2; exit 1; }

# Persist the suffix so a re-run targets the same uniquely named lab resources.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  LAB_SUFFIX="$(openssl rand -hex 4)"
  cat > "$ENV_FILE" <<ENVVARS
LAB_SUFFIX="$LAB_SUFFIX"
LOCATION="$LOCATION"
ENVVARS
  chmod 600 "$ENV_FILE"
fi

: "${LAB_SUFFIX:?LAB_SUFFIX missing from $ENV_FILE}"
LOCATION="${LOCATION:-eastus}"
ADMIN_CIDR="${ADMIN_CIDR:-$(curl -4fsS https://api.ipify.org)/32}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

VNET_NAME="vnet-revise-${LAB_SUFFIX}"
VM_SUBNET_NAME="snet-vms"
TOOLS_NSG="nsg-tools-${LAB_SUFFIX}"
APP_NSG="nsg-app-${LAB_SUFFIX}"
TOOLS_VM="vm-revise-tools-${LAB_SUFFIX}"
APP_VM="vm-revise-app-${LAB_SUFFIX}"
AKS_NAME="aks-revise-${LAB_SUFFIX}"
KV_NAME="kv-revise-${LAB_SUFFIX}"
DATA_STORAGE="stlabdata${LAB_SUFFIX}"
TFSTATE_STORAGE="stlabtfstate${LAB_SUFFIX}"
UAMI_NAME="id-aks-workload-${LAB_SUFFIX}"
DEPLOY_KEY="$HOME/.ssh/revise-lab-deploy-${LAB_SUFFIX}"
ADMIN_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  # Create a local SSH key used to access the tools VM.
  ssh-keygen -t ed25519 -C "revise-lab-admin" -f "$HOME/.ssh/id_ed25519" -N ""
fi
if [[ ! -f "$ADMIN_PUBLIC_KEY" ]]; then
  # Recover the public half if the private key already existed without its .pub file.
  ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$ADMIN_PUBLIC_KEY"
fi
if [[ ! -f "$DEPLOY_KEY" ]]; then
  # Create a dedicated key for the tools VM to SSH to the private deployment target.
  ssh-keygen -t ed25519 -C "revise-lab-deploy-${LAB_SUFFIX}" -f "$DEPLOY_KEY" -N ""
fi

cat <<SUMMARY

DevOps Revision Lab provisioning
  Resource group : $RG
  Location       : $LOCATION
  Subscription   : $SUBSCRIPTION_ID
  Admin IP/CIDR  : $ADMIN_CIDR
  Suffix         : $LAB_SUFFIX

IMPORTANT: confirm the admin CIDR is your current public IPv4 address /32.
If not, stop now and re-run with ADMIN_CIDR="YOUR.PUBLIC.IP.ADDRESS/32".
SUMMARY
read -r -p "Continue creating billable resources in $RG? Type YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 1; }

# Register providers required by AKS, VMs, storage, Key Vault, identity, and RBAC.
for provider in Microsoft.Compute Microsoft.Network Microsoft.ContainerService Microsoft.Storage Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Authorization; do
  az provider register --namespace "$provider" --wait
 done

# Create one VM subnet. AKS uses its own managed network to keep the demo simpler.
if ! az network vnet show -g "$RG" -n "$VNET_NAME" >/dev/null 2>&1; then
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET_NAME" \
    --location "$LOCATION" \
    --address-prefixes 10.20.0.0/16 \
    --subnet-name "$VM_SUBNET_NAME" \
    --subnet-prefixes 10.20.1.0/24 \
    --output none
fi

# Create the tools VM NSG and permit SSH only from the administrator's current IP.
if ! az network nsg show -g "$RG" -n "$TOOLS_NSG" >/dev/null 2>&1; then
  az network nsg create -g "$RG" -n "$TOOLS_NSG" -l "$LOCATION" --output none
fi
if ! az network nsg rule show -g "$RG" --nsg-name "$TOOLS_NSG" -n Allow-SSH-From-Admin >/dev/null 2>&1; then
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$TOOLS_NSG" --name Allow-SSH-From-Admin \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$ADMIN_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 22 --output none
else
  # Refresh the allowlist in case the administrator's public IP changed since the last run.
  az network nsg rule update -g "$RG" --nsg-name "$TOOLS_NSG" -n Allow-SSH-From-Admin \
    --source-address-prefixes "$ADMIN_CIDR" --output none
fi

# The deployment VM accepts SSH only from the private VM subnet and serves the sample app on HTTP.
if ! az network nsg show -g "$RG" -n "$APP_NSG" >/dev/null 2>&1; then
  az network nsg create -g "$RG" -n "$APP_NSG" -l "$LOCATION" --output none
fi
if ! az network nsg rule show -g "$RG" --nsg-name "$APP_NSG" -n Allow-SSH-From-Tools-Subnet >/dev/null 2>&1; then
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$APP_NSG" --name Allow-SSH-From-Tools-Subnet \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes 10.20.1.0/24 --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 22 --output none
fi
if ! az network nsg rule show -g "$RG" --nsg-name "$APP_NSG" -n Allow-HTTP >/dev/null 2>&1; then
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$APP_NSG" --name Allow-HTTP \
    --priority 110 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes Internet --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 80 --output none
fi

# Create the SonarQube/GitHub-runner tools VM, if it does not already exist.
if ! az vm show -g "$RG" -n "$TOOLS_VM" >/dev/null 2>&1; then
  az vm create \
    --resource-group "$RG" --name "$TOOLS_VM" --location "$LOCATION" \
    --image Ubuntu2404 --size "$TOOLS_VM_SIZE" \
    --admin-username "$ADMIN_USER" --authentication-type ssh \
    --ssh-key-values "$ADMIN_PUBLIC_KEY" \
    --vnet-name "$VNET_NAME" --subnet "$VM_SUBNET_NAME" \
    --nsg "$TOOLS_NSG" --nsg-rule NONE \
    --public-ip-sku Standard --os-disk-size-gb 64 --storage-sku StandardSSD_LRS \
    --tags purpose=devops-revision role=tools --output none
fi

# Create the private-by-NSG deployment target VM; public IP allows outbound internet and HTTP access.
if ! az vm show -g "$RG" -n "$APP_VM" >/dev/null 2>&1; then
  az vm create \
    --resource-group "$RG" --name "$APP_VM" --location "$LOCATION" \
    --image Ubuntu2404 --size "$APP_VM_SIZE" \
    --admin-username "$ADMIN_USER" --authentication-type ssh \
    --ssh-key-values "${DEPLOY_KEY}.pub" \
    --vnet-name "$VNET_NAME" --subnet "$VM_SUBNET_NAME" \
    --nsg "$APP_NSG" --nsg-rule NONE \
    --public-ip-sku Standard --os-disk-size-gb 32 --storage-sku StandardSSD_LRS \
    --tags purpose=devops-revision role=deployment-target --output none
fi

TOOLS_PUBLIC_IP="$(az vm show -d -g "$RG" -n "$TOOLS_VM" --query publicIps -o tsv)"
TOOLS_PRIVATE_IP="$(az vm show -d -g "$RG" -n "$TOOLS_VM" --query privateIps -o tsv)"
APP_PUBLIC_IP="$(az vm show -d -g "$RG" -n "$APP_VM" --query publicIps -o tsv)"
APP_PRIVATE_IP="$(az vm show -d -g "$RG" -n "$APP_VM" --query privateIps -o tsv)"

# Restrict the AKS API server public endpoint to the admin IP and tools VM public IP.
AKS_API_RANGES="${ADMIN_CIDR},${TOOLS_PUBLIC_IP}/32"
if ! az aks show -g "$RG" -n "$AKS_NAME" >/dev/null 2>&1; then
  # One low-cost node is for a short-lived training lab only, not production.
  az aks create \
    --resource-group "$RG" --name "$AKS_NAME" --location "$LOCATION" \
    --tier free --node-count 1 --node-vm-size "$AKS_NODE_SIZE" \
    --enable-oidc-issuer --enable-workload-identity \
    --enable-aad --enable-azure-rbac \
    --api-server-authorized-ip-ranges "$AKS_API_RANGES" \
    --generate-ssh-keys \
    --tags purpose=devops-revision role=aks --output none
else
  # Keep the public Kubernetes API restricted to the current admin and tools VM IPs.
  az aks update -g "$RG" -n "$AKS_NAME" --api-server-authorized-ip-ranges "$AKS_API_RANGES" --output none
fi

# Create the workload identity used by the sample pod.
if ! az identity show -g "$RG" -n "$UAMI_NAME" >/dev/null 2>&1; then
  az identity create -g "$RG" -n "$UAMI_NAME" -l "$LOCATION" --output none
fi

# Create the Key Vault and two Storage Accounts (workload demo + Terraform remote state).
if ! az keyvault show -g "$RG" -n "$KV_NAME" >/dev/null 2>&1; then
  az keyvault create \
    --resource-group "$RG" --name "$KV_NAME" --location "$LOCATION" \
    --sku standard --enable-rbac-authorization true --enable-purge-protection true \
    --tags purpose=devops-revision --output none
fi
if ! az storage account show -g "$RG" -n "$DATA_STORAGE" >/dev/null 2>&1; then
  az storage account create \
    --resource-group "$RG" --name "$DATA_STORAGE" --location "$LOCATION" \
    --kind StorageV2 --sku Standard_LRS --https-only true --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false \
    --tags purpose=devops-revision role=workload-identity-demo --output none
fi
if ! az storage account show -g "$RG" -n "$TFSTATE_STORAGE" >/dev/null 2>&1; then
  az storage account create \
    --resource-group "$RG" --name "$TFSTATE_STORAGE" --location "$LOCATION" \
    --kind StorageV2 --sku Standard_LRS --https-only true --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false \
    --tags purpose=devops-revision role=terraform-state --output none
fi

# Retrieve stable resource IDs and managed-identity identifiers.
AKS_ID="$(az aks show -g "$RG" -n "$AKS_NAME" --query id -o tsv)"
KV_ID="$(az keyvault show -g "$RG" -n "$KV_NAME" --query id -o tsv)"
DATA_STORAGE_ID="$(az storage account show -g "$RG" -n "$DATA_STORAGE" --query id -o tsv)"
TFSTATE_STORAGE_ID="$(az storage account show -g "$RG" -n "$TFSTATE_STORAGE" --query id -o tsv)"
IDENTITY_CLIENT_ID="$(az identity show -g "$RG" -n "$UAMI_NAME" --query clientId -o tsv)"
IDENTITY_PRINCIPAL_ID="$(az identity show -g "$RG" -n "$UAMI_NAME" --query principalId -o tsv)"
OIDC_ISSUER="$(az aks show -g "$RG" -n "$AKS_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"

# Federate the AKS namespace/service-account identity with the user-assigned managed identity.
if ! az identity federated-credential show -g "$RG" --identity-name "$UAMI_NAME" -n fic-lab-demo >/dev/null 2>&1; then
  az identity federated-credential create \
    --resource-group "$RG" --identity-name "$UAMI_NAME" --name fic-lab-demo \
    --issuer "$OIDC_ISSUER" \
    --subject "system:serviceaccount:lab-demo:workload-sa" \
    --audiences api://AzureADTokenExchange --output none
fi

# Ensure role assignments are idempotent, so a partial rerun does not fail on existing assignments.
ensure_role_assignment() {
  local principal_id="$1" principal_type="$2" role_name="$3" scope_id="$4"
  local existing_id
  existing_id="$(az role assignment list --assignee-object-id "$principal_id" --scope "$scope_id" --query "[?roleDefinitionName=='${role_name}'] | [0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$existing_id" || "$existing_id" == "None" ]]; then
    az role assignment create \
      --assignee-object-id "$principal_id" --assignee-principal-type "$principal_type" \
      --role "$role_name" --scope "$scope_id" --output none
  fi
}

# Assign least-privilege data roles to the AKS identity.
ensure_role_assignment "$IDENTITY_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User" "$KV_ID"
ensure_role_assignment "$IDENTITY_PRINCIPAL_ID" ServicePrincipal "Storage Blob Data Contributor" "$DATA_STORAGE_ID"

# Give the signed-in operator required read/write permissions for classroom seed data and Terraform state.
# This requires Owner or User Access Administrator (or equivalent role-assignment permission).
OPERATOR_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
ensure_role_assignment "$OPERATOR_OBJECT_ID" User "Key Vault Secrets Officer" "$KV_ID"
ensure_role_assignment "$OPERATOR_OBJECT_ID" User "Storage Blob Data Contributor" "$DATA_STORAGE_ID"
ensure_role_assignment "$OPERATOR_OBJECT_ID" User "Storage Blob Data Contributor" "$TFSTATE_STORAGE_ID"

# Give the operator permission to retrieve credentials and administer the classroom AKS cluster via Entra.
ensure_role_assignment "$OPERATOR_OBJECT_ID" User "Azure Kubernetes Service Cluster User Role" "$AKS_ID"
ensure_role_assignment "$OPERATOR_OBJECT_ID" User "Azure Kubernetes Service RBAC Cluster Admin" "$AKS_ID"

# Create private Blob containers with Microsoft Entra authentication (no account keys).
for attempt in 1 2 3 4 5 6; do
  if az storage container create --account-name "$DATA_STORAGE" --name lab-demo --auth-mode login --public-access off --output none; then break; fi
  [[ "$attempt" -lt 6 ]] || { echo "Could not create lab-demo container; RBAC may still be propagating. Retry after a few minutes." >&2; break; }
  sleep 15
done
for attempt in 1 2 3 4 5 6; do
  if az storage container create --account-name "$TFSTATE_STORAGE" --name tfstate --auth-mode login --public-access off --output none; then break; fi
  [[ "$attempt" -lt 6 ]] || { echo "Could not create tfstate container; RBAC may still be propagating. Retry after a few minutes." >&2; break; }
  sleep 15
done
for attempt in 1 2 3 4 5 6; do
  if az keyvault secret set --vault-name "$KV_NAME" --name lab-message --value 'secret-from-key-vault-for-workload-identity-lab' --output none; then break; fi
  [[ "$attempt" -lt 6 ]] || { echo "Could not seed Key Vault secret; RBAC may still be propagating. Retry after a few minutes." >&2; break; }
  sleep 15
done

# Set up the local kubectl client context; retry briefly while Azure RBAC permissions propagate.
for attempt in 1 2 3 4 5 6; do
  if az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing; then break; fi
  [[ "$attempt" -lt 6 ]] || { echo "Could not retrieve AKS credentials yet; retry after role assignments propagate." >&2; break; }
  sleep 15
done

cat <<SUMMARY

==================== PROVISIONING SUMMARY ====================
Resource group          : $RG
Region                  : $LOCATION
Subscription ID         : $SUBSCRIPTION_ID
Tenant ID               : $TENANT_ID
Unique suffix           : $LAB_SUFFIX

Tools/SonarQube VM      : $TOOLS_VM
Tools public IP          : $TOOLS_PUBLIC_IP
Tools private IP         : $TOOLS_PRIVATE_IP
Deployment target VM     : $APP_VM
App public IP (HTTP)     : $APP_PUBLIC_IP
App private IP           : $APP_PRIVATE_IP
AKS cluster              : $AKS_NAME
AKS API allowed ranges   : $AKS_API_RANGES
Key Vault                : $KV_NAME
Workload Storage Account : $DATA_STORAGE
Terraform State Account  : $TFSTATE_STORAGE
Terraform state container: tfstate
Workload Blob container  : lab-demo
User-assigned identity   : $UAMI_NAME
Identity client ID       : $IDENTITY_CLIENT_ID
OIDC issuer              : $OIDC_ISSUER
Deploy private key       : $DEPLOY_KEY
Environment file         : $ENV_FILE

Next steps:
1. Configure Docker + SonarQube on the tools VM, then open SonarQube with an SSH tunnel.
2. Copy the deploy private key to the tools VM and register that VM as a GitHub self-hosted runner.
3. Install Docker on the deployment target VM.
4. Complete the GitHub OIDC app/federated credential for the Terraform repo (guide provided separately).
5. Wait a few minutes for Azure role assignments to propagate before testing Key Vault/Blob access.

COST / CLEANUP:
These VMs, managed disks, public IPs, AKS worker node, and storage incur charges while allocated.
Use the cleanup instructions in the companion guide when the lab is finished.
==============================================================
SUMMARY

# Save a non-secret inventory for the companion guide and future commands.
cat >> "$ENV_FILE" <<INVENTORY
RESOURCE_GROUP="$RG"
TOOLS_VM="$TOOLS_VM"
APP_VM="$APP_VM"
AKS_NAME="$AKS_NAME"
KEY_VAULT_NAME="$KV_NAME"
DATA_STORAGE_ACCOUNT="$DATA_STORAGE"
TFSTATE_STORAGE_ACCOUNT="$TFSTATE_STORAGE"
UAMI_NAME="$UAMI_NAME"
TOOLS_PUBLIC_IP="$TOOLS_PUBLIC_IP"
TOOLS_PRIVATE_IP="$TOOLS_PRIVATE_IP"
APP_PUBLIC_IP="$APP_PUBLIC_IP"
APP_PRIVATE_IP="$APP_PRIVATE_IP"
SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
TENANT_ID="$TENANT_ID"
IDENTITY_CLIENT_ID="$IDENTITY_CLIENT_ID"
OIDC_ISSUER="$OIDC_ISSUER"
DEPLOY_KEY="$DEPLOY_KEY"
INVENTORY
chmod 600 "$ENV_FILE"
