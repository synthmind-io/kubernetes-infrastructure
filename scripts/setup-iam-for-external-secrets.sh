#!/bin/bash
# scripts/setup-iam-for-external-secrets.sh

set -euo pipefail

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-eu-central-1}"
CLUSTERS=("management" "monitoring" "dev" "devops" "staging")

# Create IAM policy for External Secrets
create_iam_policy() {
    local policy_name="HetznerExternalSecretsPolicy"
    
    cat > /tmp/external-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:/hetzner/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    # Create or update policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" &> /dev/null; then
        echo "Updating existing policy..."
        POLICY_VERSION=$(aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" --query 'Policy.DefaultVersionId' --output text)
        aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" \
            --policy-document file:///tmp/external-secrets-policy.json \
            --set-as-default
    else
        echo "Creating new policy..."
        aws iam create-policy \
            --policy-name "${policy_name}" \
            --policy-document file:///tmp/external-secrets-policy.json
    fi
    
    rm /tmp/external-secrets-policy.json
}

# Create IAM role for each cluster
create_iam_role() {
    local cluster_name=$1
    local oidc_provider=$2
    local role_name="${cluster_name}-external-secrets"
    
    # Create trust policy
    cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${oidc_provider}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_provider}:sub": "system:serviceaccount:external-secrets-system:external-secrets",
          "${oidc_provider}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

    # Create or update role
    if aws iam get-role --role-name "${role_name}" &> /dev/null; then
        echo "Updating trust policy for role ${role_name}..."
        aws iam update-assume-role-policy \
            --role-name "${role_name}" \
            --policy-document file:///tmp/trust-policy.json
    else
        echo "Creating role ${role_name}..."
        aws iam create-role \
            --role-name "${role_name}" \
            --assume-role-policy-document file:///tmp/trust-policy.json
    fi
    
    # Attach policy to role
    aws iam attach-role-policy \
        --role-name "${role_name}" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/HetznerExternalSecretsPolicy"
    
    # Tag the role
    aws iam tag-role \
        --role-name "${role_name}" \
        --tags Key=Cluster,Value="${cluster_name}" Key=Purpose,Value=external-secrets
    
    rm /tmp/trust-policy.json
    
    echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${role_name}"
}

# Main execution
echo "Setting up IAM for External Secrets..."

# Create the policy
create_iam_policy

# For each cluster, you'll need to provide the OIDC provider endpoint
echo
echo "To complete the setup, run the following for each cluster after it's created:"
echo
for cluster in "${CLUSTERS[@]}"; do
    echo "# For ${cluster} cluster:"
    echo "OIDC_PROVIDER=\$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer | sed 's|https://||')"
    echo "./setup-iam-for-external-secrets.sh create-role ${cluster} \$OIDC_PROVIDER"
    echo
done

# Handle role creation if called with parameters
if [[ "${1:-}" == "create-role" ]] && [[ -n "${2:-}" ]] && [[ -n "${3:-}" ]]; then
    create_iam_role "$2" "$3"
fi