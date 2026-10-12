#!/bin/bash
# bedrock-bootstrap: set up a least-privilege IAM role for running Claude Code on Amazon Bedrock
# in a personal AWS account, an AWS CLI profile that assumes it, and an optional cost budget.
#
# Run it with an administrator identity (IAM Identity Center or an IAM user), never the root user.
# Safe to re-run: every step creates or updates in place.

set -euo pipefail

die()  { echo "[error] $*" >&2; exit 1; }
info() { echo "[bedrock-bootstrap] $*" >&2; }
warn() { echo "[warning] $*" >&2; }

ADMIN_PROFILE="${AWS_PROFILE:-default}"
REGION="eu-west-1"
ROLE_NAME="claude-code-bedrock"
CLAUDE_PROFILE="claude-bedrock"
BUDGET_EMAIL=""
BUDGET_AMOUNT="50"
RUN_TEST=true

usage() {
  cat <<'EOF'
Usage: bedrock-bootstrap.sh [options]

  --admin-profile NAME   AWS CLI profile with admin rights (default: $AWS_PROFILE or 'default')
  --region REGION        Bedrock region to use (default: eu-west-1)
  --role-name NAME       IAM role to create (default: claude-code-bedrock)
  --profile-name NAME    AWS CLI profile to write for Claude Code (default: claude-bedrock)
  --budget-email EMAIL   create a monthly account cost budget that emails this address
  --budget-amount USD    monthly budget amount (default: 50)
  --no-test              skip the test model invocation
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --admin-profile) ADMIN_PROFILE="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --role-name)     ROLE_NAME="$2"; shift 2 ;;
    --profile-name)  CLAUDE_PROFILE="$2"; shift 2 ;;
    --budget-email)  BUDGET_EMAIL="$2"; shift 2 ;;
    --budget-amount) BUDGET_AMOUNT="$2"; shift 2 ;;
    --no-test)       RUN_TEST=false; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "The AWS CLI v2 is required: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
aws --version 2>&1 | grep -q '^aws-cli/2' || die "AWS CLI v2 is required; found: $(aws --version 2>&1)"

ADMIN=(--profile "$ADMIN_PROFILE")

# ── who is running this ───────────────────────────────────────────────────────

CALLER_ARN="$(aws sts get-caller-identity "${ADMIN[@]}" --query Arn --output text 2>/dev/null)" \
  || die "Could not get credentials for profile '$ADMIN_PROFILE'. Sign in first (aws sso login --profile $ADMIN_PROFILE, or aws login)."
ACCOUNT_ID="$(aws sts get-caller-identity "${ADMIN[@]}" --query Account --output text)"
info "Account $ACCOUNT_ID, running as $CALLER_ARN"

case "$CALLER_ARN" in
  *":root") die "Don't use the root user. Create an admin identity first (see the console steps)." ;;
  *":assumed-role/"*)
    caller_role="$(printf '%s' "$CALLER_ARN" | cut -d/ -f2)"
    PRINCIPAL_ARN="$(aws iam get-role "${ADMIN[@]}" --role-name "$caller_role" --query Role.Arn --output text)" \
      || die "Could not resolve the IAM role behind $CALLER_ARN"
    # Assuming a role from a role session is role chaining, which AWS caps at one hour.
    SESSION_SECONDS=3600
    ;;
  *":user/"*)
    PRINCIPAL_ARN="$CALLER_ARN"
    SESSION_SECONDS=43200
    ;;
  *) die "Unrecognised caller type: $CALLER_ARN" ;;
esac
info "The role will be assumable only by $PRINCIPAL_ARN"

# ── role ──────────────────────────────────────────────────────────────────────

# Trusting the account root with a PrincipalArn condition keeps the trust valid if an Identity
# Center role is recreated with a new unique ID, while still admitting only that one identity.
TRUST_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:root" },
    "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
    "Condition": { "ArnEquals": { "aws:PrincipalArn": "${PRINCIPAL_ARN}" } }
  }]
}
EOF
)"

# Claude Code's documented policy, narrowed from all foundation models to Anthropic's.
PERMISSIONS_POLICY="$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeAnthropicModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*anthropic.*",
        "arn:aws:bedrock:*:*:application-inference-profile/*",
        "arn:aws:bedrock:*::foundation-model/anthropic.*"
      ]
    },
    {
      "Sid": "DiscoverInferenceProfiles",
      "Effect": "Allow",
      "Action": ["bedrock:ListInferenceProfiles"],
      "Resource": "*"
    },
    {
      "Sid": "AllowMarketplaceSubscriptionViaBedrock",
      "Effect": "Allow",
      "Action": ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:CalledViaLast": "bedrock.amazonaws.com" } }
    }
  ]
}
EOF
)"

if aws iam get-role "${ADMIN[@]}" --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  info "Updating existing role $ROLE_NAME"
  aws iam update-assume-role-policy "${ADMIN[@]}" --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  info "Creating role $ROLE_NAME"
  aws iam create-role "${ADMIN[@]}" --role-name "$ROLE_NAME" \
    --description "Claude Code on Amazon Bedrock (personal use)" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=purpose,Value=claude-code >/dev/null
fi
aws iam update-role "${ADMIN[@]}" --role-name "$ROLE_NAME" --max-session-duration 43200
aws iam put-role-policy "${ADMIN[@]}" --role-name "$ROLE_NAME" \
  --policy-name claude-code-bedrock-invoke --policy-document "$PERMISSIONS_POLICY"
ROLE_ARN="$(aws iam get-role "${ADMIN[@]}" --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# ── CLI profile ───────────────────────────────────────────────────────────────

aws configure set role_arn "$ROLE_ARN" --profile "$CLAUDE_PROFILE"
aws configure set source_profile "$ADMIN_PROFILE" --profile "$CLAUDE_PROFILE"
aws configure set role_session_name claude-code --profile "$CLAUDE_PROFILE"
aws configure set duration_seconds "$SESSION_SECONDS" --profile "$CLAUDE_PROFILE"
aws configure set region "$REGION" --profile "$CLAUDE_PROFILE"
info "Wrote profile '$CLAUDE_PROFILE' to ~/.aws/config (sessions of $((SESSION_SECONDS / 3600))h)"

# ── budget ────────────────────────────────────────────────────────────────────

if [ -n "$BUDGET_EMAIL" ]; then
  BUDGET_NAME="monthly-account-spend"
  if aws budgets describe-budget "${ADMIN[@]}" --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
    info "Budget $BUDGET_NAME already exists; leaving it unchanged"
  else
    # An account-wide budget, because Anthropic models can be billed through AWS Marketplace
    # rather than under the Amazon Bedrock service, which a service filter would miss.
    aws budgets create-budget "${ADMIN[@]}" --account-id "$ACCOUNT_ID" \
      --budget "{\"BudgetName\":\"$BUDGET_NAME\",\"BudgetLimit\":{\"Amount\":\"$BUDGET_AMOUNT\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
      --notifications-with-subscribers "[
        {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":50,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$BUDGET_EMAIL\"}]},
        {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$BUDGET_EMAIL\"}]},
        {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$BUDGET_EMAIL\"}]}
      ]"
    info "Created a \$$BUDGET_AMOUNT monthly budget alerting $BUDGET_EMAIL at 50%, 100% and forecast 100%"
  fi
fi

# ── verify ────────────────────────────────────────────────────────────────────

info "Waiting for IAM changes to propagate..."
assumed=false
for _ in 1 2 3 4 5 6; do
  if aws sts get-caller-identity --profile "$CLAUDE_PROFILE" >/dev/null 2>&1; then assumed=true; break; fi
  sleep 5
done
[ "$assumed" = true ] || die "Could not assume $ROLE_ARN via profile '$CLAUDE_PROFILE'."
info "Assumed $ROLE_NAME successfully"

PROFILES="$(aws bedrock list-inference-profiles --profile "$CLAUDE_PROFILE" --region "$REGION" \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic')].inferenceProfileId" \
  --output text 2>/dev/null | tr '\t' '\n' | sort)" || PROFILES=""

if [ -z "$PROFILES" ]; then
  warn "No Anthropic inference profiles visible in $REGION. Try another region with --region."
else
  echo ""
  echo "Anthropic inference profiles available from $REGION:"
  printf '  %s\n' $PROFILES
fi

if [ "$RUN_TEST" = true ] && [ -n "$PROFILES" ]; then
  TEST_MODEL="$(printf '%s\n' $PROFILES | grep -i haiku | tail -n1 || true)"
  [ -n "$TEST_MODEL" ] || TEST_MODEL="$(printf '%s\n' $PROFILES | tail -n1)"
  out="$(mktemp)"
  info "Test invocation of $TEST_MODEL (a few tokens; billed)"
  if aws bedrock-runtime invoke-model --profile "$CLAUDE_PROFILE" --region "$REGION" \
       --model-id "$TEST_MODEL" --cli-binary-format raw-in-base64-out \
       --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":20,"messages":[{"role":"user","content":"Reply with the single word: ready"}]}' \
       "$out" >/dev/null 2>"$out.err"; then
    info "Model replied: $(grep -o '"text":"[^"]*"' "$out" | head -n1 | cut -d'"' -f4)"
  else
    warn "Test invocation failed: $(tr '\n' ' ' < "$out.err")"
    warn "If it mentions access or a use case, submit the Anthropic use case form in the Bedrock console and retry."
  fi
  rm -f "$out" "$out.err"
fi

cat <<EOF

Done. Next, start Claude Code on the host and run the setup wizard:

  AWS_PROFILE=$CLAUDE_PROFILE claude      # then: 3rd-party platform → Amazon Bedrock
                                          # or, if already signed in, type /setup-bedrock

Choose the '$CLAUDE_PROFILE' profile and region $REGION, then pin the models listed above.
EOF
if [ "$SESSION_SECONDS" = 3600 ]; then
  cat <<EOF
Your admin identity is an Identity Center role, so sessions last an hour and refresh from your
SSO login. Add this to ~/.claude/settings.json so Claude Code can renew an expired SSO login:

  "awsAuthRefresh": "aws sso login --profile $ADMIN_PROFILE"
EOF
fi
