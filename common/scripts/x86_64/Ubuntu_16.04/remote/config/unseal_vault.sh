#! /bin/bash
set -e

readonly VAULT_API_RESPONSE_FILE="/tmp/.vault_response"
readonly ADMIRAL_ENV="/etc/shippable/admiral.env"
readonly BOOT_WAIT=10
export VAULT_INITIALIZED=false
##################### Begin Vault adapter ######################################

__initialize_adapter() {
  echo "Initializing vault api adapter"
  RESPONSE_CODE=404
  RESPONSE_DATA=""
  CURL_EXIT_CODE=0

  ## VAULT_URL is imported from this config

  rm -f $VAULT_API_RESPONSE_FILE || true
  touch $VAULT_API_RESPONSE_FILE
}

__vault_get() {
  __initialize_adapter

  local url="$VAULT_URL/v1/$1"
  {
    RESPONSE_CODE=$(curl \
      -X GET $url \
      -H "Content-Type: application/json" \
      --silent --write-out "%{http_code}\n" \
      --output $VAULT_API_RESPONSE_FILE)
  } || {
    CURL_EXIT_CODE=$(echo $?)
  }

  if [ $CURL_EXIT_CODE -gt 0 ]; then
    echo "GET $url failed with error code $CURL_EXIT_CODE"
    echo "Please check $VAULT_API_RESPONSE_FILE for more details"
    # we are assuming that if curl cmd failed, vault API is unavailable
    response="curl failed with error code $CURL_EXIT_CODE. vault might be down."
    response_status_code=503
  else
    response_status_code="$RESPONSE_CODE"
    response=$(cat $VAULT_API_RESPONSE_FILE)
  fi

  rm -f $VAULT_API_RESPONSE_FILE
}

__vault_put() {
  __initialize_adapter

  local url="$VAULT_URL/v1/$1"
  local update="$2"
  {
    RESPONSE_CODE=$(curl \
      -X PUT $url \
      -H "Content-Type: application/json" \
      -d "$update" \
      --write-out "%{http_code}\n" \
      --silent \
      --output $VAULT_API_RESPONSE_FILE)
  } || {
    CURL_EXIT_CODE=$(echo $?)
  }

  if [ $CURL_EXIT_CODE -gt 0 ]; then
    echo "PUT $url failed with error code $CURL_EXIT_CODE"
    echo "Please check $VAULT_API_RESPONSE_FILE for more details"
    # we are assuming that if curl cmd failed, vault API is unavailable
    response="curl failed with error code $CURL_EXIT_CODE. vault might be down."
    response_status_code=503
  else
    response_status_code="$RESPONSE_CODE"
    response=$(cat $VAULT_API_RESPONSE_FILE)
  fi

  rm -f $VAULT_API_RESPONSE_FILE
}

## Methods
_vault_get_status() {
  local vault_status_endpoint="sys/health"
  __vault_get $vault_status_endpoint
}

_vault_unseal() {
  local vault_unseal_endpoint="sys/unseal"
  local unseal_payload="$1"
  __vault_put $vault_unseal_endpoint "$unseal_payload"
}

##################### End Vault adapter ######################################

__generate_unseal_payload() {
  local unseal_key="$1"
  payload='{"key": "'$unseal_key'"}'
}

__initialize() {
  if [ ! -f "$ADMIRAL_ENV" ]; then
    ## better formatting in systemd logs
    echo ""
    echo "Vault is installed on a different host from admiral"
    echo "It can only be unsealed from admiral host or an authenticated call to admiral API"
    echo "run 'sudo ./admiral.sh restart' on the admiral host to unseal vault"

  else
    source $ADMIRAL_ENV

    if [ ! -z "$VAULT_URL" ] && [ ! -z "$VAULT_TOKEN" ]; then
      VAULT_INITIALIZED=true
    fi
  fi
}

__unseal_vault() {
  echo "Unsealing vault server"
  echo "Waiting $BOOT_WAIT seconds for vault server to start"
  sleep $BOOT_WAIT

  _vault_get_status
  local initialized_status=$(echo $response \
    | jq -r '.initialized')
  local sealed_status=$(echo $response \
    | jq -r '.sealed')

  if [ "$initialized_status" == "true" ]; then
    echo "Vault has already been initialized, proceeding to unseal it"
    if [ "$sealed_status" == "true" ]; then
      __generate_unseal_payload "$VAULT_UNSEAL_KEY1"
      _vault_unseal "$payload"
      echo "Unseal response: $response"

      __generate_unseal_payload "$VAULT_UNSEAL_KEY2"
      _vault_unseal "$payload"
      echo "Unseal response: $response"

      __generate_unseal_payload "$VAULT_UNSEAL_KEY3"
      _vault_unseal "$payload"
      echo "Unseal response: $response"

    else
      echo "Vault already unsealed, skipping unseal steps"
    fi
  else
    echo "Vault not initialized. Initialize vault before trying to unseal it"
  fi
}

__initialize
if [ "$VAULT_INITIALIZED" == "true" ]; then
  __unseal_vault
else
  echo "Vault not initialized or missing config, skipping unseal"
fi
