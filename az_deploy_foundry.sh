#!/usr/bin/env bash
# 登录后运行：az login，然后 bash az_deploy_foundry.sh（Azure Cloud Shell 已登录可直接运行）。
# 依赖 Bash、Azure CLI、jq；独立运行，不读取 support_dict.json，也不提交 ARM 模板。
# 修改下面的配置，或使用环境变量：
# DEPLOY_NAME=my-foundry REGIONS="spaincentral swedencentral" bash az_deploy_foundry.sh
# DEPLOY_NAME=my-foundry bash az_deploy_foundry.sh --models gpt-5.6-sol,gpt-6-astra
# DEPLOY_NAME=my-foundry MODELS="gpt-5.6-sol gpt-6-astra" bash az_deploy_foundry.sh
# bash az_deploy_foundry.sh --list-models 可查看全部可选部署名。
# 同名旧 OpenAI 资源需要先升级为 Foundry，或更换 DEPLOY_NAME 新建。
# 执行结束后集中打印本次账号的 URL 和密钥，并保存到 foundry_keys.txt / foundry_keys.jsonl。
# https://learn.microsoft.com/cli/azure/use-azure-cli-rest-command
# https://learn.microsoft.com/azure/foundry/how-to/create-projects

set +x
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_NAME="${DEPLOY_NAME:-your-deploy-prefix}"
REGIONS="${REGIONS:-spaincentral}"              # 多区域用空格分隔，填写 Azure 区域代码。
MODELS="${MODELS-gpt-5.4,gpt-5.5,gpt-5.6-sol,gpt-6-astra}" # 逗号或空白分隔；--models 优先。
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"           # 留空使用 az login 后当前选中的订阅。
RESOURCE_GROUP="${RESOURCE_GROUP:-azure}"
GROUP_LOCATION="${GROUP_LOCATION:-eastus2}"
PROJECT_NAME="${PROJECT_NAME:-proj-default}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1200}"
MAX_RETRIES=3
API_VERSION="2026-07-01"
ARM="https://management.azure.com"

# 参考 support_dict.json 的 empty3（2026-10-31），按部署名合并各区域的相同配置。
# 部署名 | 模型名 | 版本 | SKU | 容量。-dz 是部署名后缀，不属于 Azure 模型名。
# 每个 REGIONS 区域均尝试所选部署项；实际区域支持和配额由 Azure 校验。
MODEL_CATALOG=(
    "gpt-4.1-mini|gpt-4.1-mini|2025-04-14|GlobalStandard|5000"
    "gpt-4.1-mini-dz|gpt-4.1-mini|2025-04-14|DataZoneStandard|2000"
    "gpt-4o|gpt-4o|2024-11-20|GlobalStandard|450"
    "gpt-4o-dz|gpt-4o|2024-11-20|DataZoneStandard|300"
    "gpt-5-mini|gpt-5-mini|2025-08-07|GlobalStandard|1000"
    "gpt-5-mini-dz|gpt-5-mini|2025-08-07|DataZoneStandard|300"
    "gpt-5.1|gpt-5.1|2025-11-13|GlobalStandard|250"
    "gpt-5.1-dz|gpt-5.1|2025-11-13|DataZoneStandard|100"
    "gpt-5.2|gpt-5.2|2025-12-11|GlobalStandard|250"
    "gpt-5.2-dz|gpt-5.2|2025-12-11|DataZoneStandard|100"
    "gpt-5.4|gpt-5.4|2026-03-05|GlobalStandard|250"
    "gpt-5.4-dz|gpt-5.4|2026-03-05|DataZoneStandard|100"
    "gpt-5.4-mini|gpt-5.4-mini|2026-03-17|GlobalStandard|1000"
    "gpt-5.4-nano|gpt-5.4-nano|2026-03-17|GlobalStandard|5000"
    "gpt-5.4-nano-dz|gpt-5.4-nano|2026-03-17|DataZoneStandard|2000"
    "gpt-5.5|gpt-5.5|2026-04-24|GlobalStandard|1000"
    "gpt-5.5-dz|gpt-5.5|2026-04-24|DataZoneStandard|333"
    "gpt-5.6-luna|gpt-5.6-luna|2026-07-09|GlobalStandard|250"
    "gpt-5.6-luna-dz|gpt-5.6-luna|2026-07-09|DataZoneStandard|100"
    "gpt-5.6-sol|gpt-5.6-sol|2026-07-09|GlobalStandard|250"
    "gpt-5.6-sol-dz|gpt-5.6-sol|2026-07-09|DataZoneStandard|100"
    "gpt-5.6-terra|gpt-5.6-terra|2026-07-09|GlobalStandard|250"
    "gpt-5.6-terra-dz|gpt-5.6-terra|2026-07-09|DataZoneStandard|100"
    "gpt-6-astra|gpt-6-astra|2026-09-03|GlobalStandard|250"
    "gpt-6-astra-dz|gpt-6-astra|2026-09-03|DataZoneStandard|100"
    "gpt-6-luna|gpt-6-luna|2026-09-22|GlobalStandard|250"
    "gpt-6-luna-dz|gpt-6-luna|2026-09-22|DataZoneStandard|100"
    "gpt-6-sol|gpt-6-sol|2026-09-22|GlobalStandard|250"
    "gpt-6-sol-dz|gpt-6-sol|2026-09-22|DataZoneStandard|100"
    "gpt-6.1-sol|gpt-6.1-sol|2026-09-29|GlobalStandard|250"
    "gpt-6.1-sol-dz|gpt-6.1-sol|2026-09-29|DataZoneStandard|100"
    "gpt-image-1|gpt-image-1|2025-04-15|GlobalStandard|3"
    "gpt-image-1.5|gpt-image-1.5|2025-12-16|GlobalStandard|9"
    "gpt-image-1.5-dz|gpt-image-1.5|2025-12-16|DataZoneStandard|3"
    "gpt-image-2|gpt-image-2|2026-04-21|GlobalStandard|2"
)
MODEL_SPECS=()

ARM_RESPONSE="{}"
LAST_ERROR=""
STAGE=""
CURRENT_RESOURCE=""
FAILURES=0
MODEL_SUCCESSES=0
KEY_COUNT=0
KEY_SUMMARY=()

log() { printf '%s\n' "$*" >&2; }
fail() { LAST_ERROR="$*"; log "错误：$LAST_ERROR"; return 1; }
uri() { jq -rn --arg value "$1" '$value | @uri'; }

usage() {
    cat <<'EOF'
用法：DEPLOY_NAME=my-foundry bash az_deploy_foundry.sh [选项]

  --models, -m LIST  仅部署指定模型，使用逗号或空白分隔（空白列表需加引号）。
  --list-models     列出可选部署名、模型名、版本、SKU 和容量，不调用 Azure。
  --help, -h        显示帮助。

未指定 --models 时读取 MODELS 环境变量；二者都未设置时部署原有四个模型：
gpt-5.4,gpt-5.5,gpt-5.6-sol,gpt-6-astra。
同一列表应用于 REGIONS 的每个区域；重复名称只部署一次，未知名称或空列表报错。
可选项来自 support_dict.json 的 empty3 快照，运行时无需该文件。
-dz 部署项使用 DataZoneStandard；实际区域支持及配额由 Azure 校验。

示例：
  DEPLOY_NAME=my-foundry bash az_deploy_foundry.sh --models gpt-5.6-sol,gpt-6-astra
  DEPLOY_NAME=my-foundry MODELS="gpt-6.1-sol gpt-image-2" REGIONS=swedencentral bash az_deploy_foundry.sh
EOF
}

list_models() {
    local spec deployment model version sku capacity
    printf '%s\t%s\t%s\t%s\t%s\n' '部署名（--models）' '模型名' '版本' 'SKU' '容量'
    for spec in "${MODEL_CATALOG[@]}"; do
        IFS='|' read -r deployment model version sku capacity <<<"$spec"
        printf '%s\t%s\t%s\t%s\t%s\n' "$deployment" "$model" "$version" "$sku" "$capacity"
    done
}

select_models() {
    local model spec found
    local -a requested=() selected=()
    read -r -a requested <<<"$(printf '%s' "$MODELS" | tr ',[:space:]' ' ')"
    (( ${#requested[@]} > 0 )) || { log "模型列表不能为空，请使用 --models 或 MODELS 指定模型。"; return 1; }
    MODEL_SPECS=()
    for model in "${requested[@]}"; do
        [[ " ${selected[*]} " != *" $model "* ]] || continue
        found=false
        for spec in "${MODEL_CATALOG[@]}"; do
            [[ "${spec%%|*}" == "$model" ]] || continue
            MODEL_SPECS+=("$spec")
            selected+=("$model")
            found=true
            break
        done
        if [[ "$found" == false ]]; then
            log "未知模型：$model；请运行 bash az_deploy_foundry.sh --list-models 查看可选部署名。"
            return 1
        fi
    done
    log "本次部署模型：${selected[*]}"
}

# az rest 自动复用 Azure CLI 登录凭据。仅明确的资源不存在返回 4，权限错误不能当作不存在。
arm_request() {
    local method="$1" url="$2" body="${3:-}" allow_missing="${4:-false}" attempt=0
    local -a args=(rest --method "$method" --url "$url" --subscription "$SUBSCRIPTION_ID"
                   --only-show-errors --output json)
    if [[ -n "$body" ]]; then
        args+=(--headers "Content-Type=application/json" --body "$body")
    fi
    ARM_RESPONSE="{}"
    while true; do
        if ARM_RESPONSE="$(az "${args[@]}" 2>"$ERROR_FILE")"; then
            ARM_RESPONSE="${ARM_RESPONSE:-\{\}}"
            return 0
        fi
        LAST_ERROR="$(cat "$ERROR_FILE")"
        if [[ "$method" == GET && "$allow_missing" == true ]] &&
            grep -Eq 'ResourceNotFound|ResourceGroupNotFound|AccountNotFound|ProjectNotFound|DeploymentNotFound|(^|[ :(])NotFound([ :({]|$)' "$ERROR_FILE"; then
            ARM_RESPONSE="{}"
            return 4
        fi
        if (( attempt < MAX_RETRIES )) &&
            grep -Eqi 'TooManyRequests|Too Many Requests|ServiceUnavailable|InternalServerError|BadGateway|GatewayTimeout|ConnectionError|Connection reset|timed out|HTTP[^0-9]*(429|500|502|503|504)' "$ERROR_FILE"; then
            attempt=$((attempt + 1))
            log "请求暂时失败，重试 $attempt/$MAX_RETRIES：$method"
            sleep "$((POLL_INTERVAL + attempt * 2))"
            continue
        fi
        log "$LAST_ERROR"
        return 1
    done
}

# 每一步确认成功后才继续。超时说明资源状态未确定，终止本次运行，避免继续提交模型。
wait_ready() {
    local url="$1" description="$2" field="${3:-properties.provisioningState}"
    local target="${4:-succeeded}" started=$SECONDS state rc
    while true; do
        state="$(jq -r --arg field "$field" 'getpath($field | split(".")) // ""' <<<"$ARM_RESPONSE")" || return 1
        state="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
        case "$state" in
            "$target") log "$description：完成"; return 0 ;;
            failed|canceled|cancelled)
                fail "$description：$state $(jq -c '.error // .properties.error // {}' <<<"$ARM_RESPONSE")"
                return 1 ;;
        esac
        if (( SECONDS - started >= WAIT_TIMEOUT )); then
            log "$description：等待超时，已停止。请检查 Azure 资源状态后再运行。"
            exit 124
        fi
        log "$description：${state:-等待资源就绪}"
        sleep "$POLL_INTERVAL"
        if arm_request GET "$url" "" true; then
            :
        else
            rc=$?
            [[ "$rc" == 4 ]] || return 1
        fi
    done
}

record_failure() {
    local region="$1"
    FAILURES=$((FAILURES + 1))
    jq -cn --arg region "$region" --arg stage "$STAGE" --arg resource "$CURRENT_RESOURCE" \
        --arg error "$LAST_ERROR" '{location:$region,step:$stage,resource:$resource,error:$error}' >>"$FAILURE_FILE"
    log "失败：$region / $STAGE / $CURRENT_RESOURCE"
}

prepare_subscription() {
    local provider="$ARM/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.CognitiveServices"
    local url="$provider?api-version=2021-04-01" state body rc
    arm_request GET "$url" || return 1
    state="$(jq -r '.registrationState' <<<"$ARM_RESPONSE")"
    if [[ "$state" != Registered && "$state" != Registering ]]; then
        arm_request POST "$provider/register?api-version=2021-04-01" || return 1
    fi
    wait_ready "$url" "注册 Microsoft.CognitiveServices" registrationState registered || return 1
    url="$GROUP_URL?api-version=2021-04-01"
    if arm_request GET "$url" "" true; then
        log "复用资源组：$RESOURCE_GROUP"
    else
        rc=$?
        [[ "$rc" == 4 ]] || return 1
        body="$(jq -cn --arg location "$GROUP_LOCATION" '{location:$location}')"
        arm_request PUT "$url" "$body" || return 1
    fi
    wait_ready "$url" "资源组 $RESOURCE_GROUP"
}

require_foundry() {
    local name="$1" region="$2"
    if ! jq -e --arg region "$region" '
        .kind == "AIServices" and .properties.allowProjectManagement == true
        and (.location | ascii_downcase | gsub(" "; "")) == $region
    ' <<<"$ARM_RESPONSE" >/dev/null; then
        fail "$name 不是位于 $region 且已启用项目管理的 Foundry 资源；请先升级旧资源，或换 DEPLOY_NAME 新建。"
        return 1
    fi
}

deploy_region() {
    local region="$1" suffix name account url body rc endpoint spec deployment model version sku capacity key models_json
    local -a successful_models=()
    suffix="$(printf '%s' "$region" | tr 'abcdefghijklmnopqrstuvwxyz0123456789' 'qwertyuiopasdfghjklzxcvbnm5790241368')"
    name="$DEPLOY_NAME-$suffix"
    account="$GROUP_URL/providers/Microsoft.CognitiveServices/accounts/$name"
    STAGE=account
    CURRENT_RESOURCE="$name"
    log ""
    log "开始区域：$region，Foundry 账号：$name"
    url="$account?api-version=$API_VERSION"
    if arm_request GET "$url" "" true; then
        require_foundry "$name" "$region" || return 1
        log "复用 Foundry 账号：$name"
    else
        rc=$?
        [[ "$rc" == 4 ]] || return 1
        body="$(jq -cn --arg location "$region" --arg name "$name" --arg project "$PROJECT_NAME" '{
            location:$location,kind:"AIServices",sku:{name:"S0"},identity:{type:"SystemAssigned"},
            properties:{customSubDomainName:$name,allowProjectManagement:true,
                defaultProject:$project,associatedProjects:[$project],publicNetworkAccess:"Enabled",
                networkAcls:{defaultAction:"Allow",virtualNetworkRules:[],ipRules:[]}}
        }')" || return 1
        arm_request PUT "$url" "$body" || return 1
    fi
    wait_ready "$url" "Foundry 账号 $name" || return 1
    require_foundry "$name" "$region" || return 1
    endpoint="$(jq -r '.properties.endpoint // empty' <<<"$ARM_RESPONSE")"
    endpoint="${endpoint:-https://$name.cognitiveservices.azure.com/}"
    endpoint="${endpoint%/}/"

    STAGE=project
    CURRENT_RESOURCE="$PROJECT_NAME"
    url="$account/projects/$(uri "$PROJECT_NAME")?api-version=$API_VERSION"
    if arm_request GET "$url" "" true; then
        if ! jq -e --arg region "$region" '(.location | ascii_downcase | gsub(" "; "")) == $region' <<<"$ARM_RESPONSE" >/dev/null; then
            fail "已有项目 $PROJECT_NAME 的区域与 $region 不一致"
            return 1
        fi
    else
        rc=$?
        [[ "$rc" == 4 ]] || return 1
        body="$(jq -cn --arg location "$region" --arg project "$PROJECT_NAME" '{
            location:$location,identity:{type:"SystemAssigned"},
            properties:{displayName:$project,description:"Default project created with the resource"}
        }')" || return 1
        arm_request PUT "$url" "$body" || return 1
    fi
    wait_ready "$url" "Foundry 项目 $region/$PROJECT_NAME" || return 1

    STAGE=model
    for spec in "${MODEL_SPECS[@]}"; do
        IFS='|' read -r deployment model version sku capacity <<<"$spec"
        CURRENT_RESOURCE="$deployment"
        log "部署模型：$deployment（$model），版本：$version，$sku 容量：$capacity"
        body="$(jq -cn --arg model "$model" --arg version "$version" --arg sku "$sku" --argjson capacity "$capacity" '{
            sku:{name:$sku,capacity:$capacity},
            properties:{model:{format:"OpenAI",name:$model,version:$version},
                versionUpgradeOption:"OnceCurrentVersionExpired",raiPolicyName:"Microsoft.Nil"}
        }')" || return 1
        url="$account/deployments/$(uri "$deployment")?api-version=$API_VERSION"
        if arm_request PUT "$url" "$body" && wait_ready "$url" "模型 $region/$deployment"; then
            successful_models+=("$deployment")
            MODEL_SUCCESSES=$((MODEL_SUCCESSES + 1))
        else
            # 当前区域不支持模型或配额不足时记录失败，继续尝试余下的所选模型。
            record_failure "$region"
        fi
    done

    STAGE=keys
    CURRENT_RESOURCE="$name"
    arm_request POST "$account/listKeys?api-version=$API_VERSION" || return 1
    key="$(jq -er '.key1 | select(type == "string" and length > 0)' <<<"$ARM_RESPONSE")" || {
        fail "$name 未返回 key1"
        return 1
    }
    models_json="$(printf '%s\n' "${successful_models[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    printf '%s\n%s\n' "$endpoint" "$key" >>"$KEYS_TXT" || return 1
    jq -cn --arg name "$name" --arg region "$region" --arg endpoint "$endpoint" --arg key "$key" \
        --argjson models "$models_json" \
        '{deploy_name:$name,location:$region,endpoint:$endpoint,key:$key,models:$models}' >>"$KEYS_JSONL" || return 1
    KEY_COUNT=$((KEY_COUNT + 1))
    KEY_SUMMARY+=("账号：$name（$region）"$'\n'"URL：$endpoint"$'\n'"密钥：$key")
    log "账号密钥已保存：$name（$KEYS_JSONL）"
}

main() {
    local command login region account_name
    local -a subscription_args=() regions=()
    while (( $# > 0 )); do
        case "$1" in
            --models|-m)
                (( $# >= 2 )) && [[ "$2" != -* ]] || { log "$1 需要模型列表参数。"; return 1; }
                MODELS="$2"
                shift 2 ;;
            --models=*) MODELS="${1#*=}"; shift ;;
            --list-models) list_models; return 0 ;;
            --help|-h) usage; return 0 ;;
            *) log "未知参数：$1"; usage >&2; return 1 ;;
        esac
    done
    select_models || return 1
    for command in az jq; do
        command -v "$command" >/dev/null 2>&1 || { log "缺少命令：$command"; return 1; }
    done
    DEPLOY_NAME="$(printf '%s' "$DEPLOY_NAME" | tr -d '[:space:]' | tr '[:upper:]_.' '[:lower:]--')"
    [[ "$DEPLOY_NAME" != your-deploy-prefix && "$DEPLOY_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        log "请先设置 DEPLOY_NAME，例如：DEPLOY_NAME=my-foundry bash az_deploy_foundry.sh"; return 1;
    }
    [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,63}$ ]] || { log "PROJECT_NAME 格式无效"; return 1; }
    [[ "$POLL_INTERVAL" =~ ^[0-9]+$ && "$WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
        log "POLL_INTERVAL 必须为非负整数，WAIT_TIMEOUT 必须为正整数"; return 1;
    }
    read -r -a regions <<<"$REGIONS"
    (( ${#regions[@]} > 0 )) || { log "REGIONS 不能为空"; return 1; }
    for region in "${regions[@]}"; do
        [[ "$region" =~ ^[a-z0-9]+$ ]] || { log "请使用小写区域代码：$region"; return 1; }
        account_name="$DEPLOY_NAME-$region"  # 区域编码替换不改变长度。
        (( ${#account_name} <= 64 )) || { log "账号名称超过 64 字符，请缩短 DEPLOY_NAME"; return 1; }
    done
    [[ -z "$SUBSCRIPTION_ID" ]] || subscription_args+=(--subscription "$SUBSCRIPTION_ID")
    login="$(az account show "${subscription_args[@]}" --only-show-errors --output json)" || {
        log "无法读取登录状态，请先执行 az login 并选定订阅。"; return 1;
    }
    SUBSCRIPTION_ID="$(jq -er '.id | select(type == "string" and length > 0)' <<<"$login")"
    jq -e '.state == "Enabled"' <<<"$login" >/dev/null || { log "所选订阅不是 Enabled 状态"; return 1; }
    log "使用订阅：$SUBSCRIPTION_ID；区域：$REGIONS；资源组：$RESOURCE_GROUP"
    GROUP_URL="$ARM/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$(uri "$RESOURCE_GROUP")"
    mkdir -p -- "$OUTPUT_DIR"
    KEYS_TXT="$OUTPUT_DIR/foundry_keys.txt"
    KEYS_JSONL="$OUTPUT_DIR/foundry_keys.jsonl"
    FAILURE_FILE="$OUTPUT_DIR/foundry_failures.jsonl"
    ERROR_FILE="$(mktemp)"
    trap 'rm -f -- "$ERROR_FILE"' EXIT
    prepare_subscription || return 1
    for region in "${regions[@]}"; do
        if deploy_region "$region"; then
            :
        else
            record_failure "$region"
        fi
    done
    log ""
    log "部署结束：成功模型 $MODEL_SUCCESSES 个，已保存密钥 $KEY_COUNT 组，失败 $FAILURES 项。"
    if (( FAILURES > 0 )); then
        log "失败详情：$FAILURE_FILE"
    fi
    if (( KEY_COUNT > 0 )); then
        printf '\n本次部署的 URL 和密钥：\n\n'
        printf '%s\n\n' "${KEY_SUMMARY[@]}"
    fi
    if (( FAILURES > 0 )); then
        return 1
    fi
}

main "$@"
