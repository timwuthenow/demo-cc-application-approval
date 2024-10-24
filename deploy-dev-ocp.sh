#!/bin/bash

# Prompt for namespace
read -p "Input Namespace: " NAMESPACE

# Confirm service name
SERVICE_NAME="cc-application-approval"
BASE_URL=apps.sandbox-m2.ll9k.p1.openshiftapps.com
# Remove /auth from the base URL since it will be added in the endpoints
# Normal Keycloak Deployment uncomment
#KEYCLOAK_BASE_URL="keycloak-$NAMESPACE.$BASE_URL"
KEYCLOAK_BASE_URL="keycloak-timothywuthenow-dev.$BASE_URL"

# Keycloak configuration
REALM="jbpm-openshift"
CLIENT_ID="task-console"
ADMIN_USERNAME="admin"
read -s -p "Enter Keycloak admin password: " ADMIN_PASSWORD
echo

echo "Keycloak Base URL is: " $KEYCLOAK_BASE_URL
read -p "Confirm service name ($SERVICE_NAME)? [Y/n]: " CONFIRM
if [[ $CONFIRM =~ ^[Nn]$ ]]; then
    read -p "Enter new service name: " SERVICE_NAME
fi

# Derive console names from service name
TASK_CONSOLE_NAME="${SERVICE_NAME}-task-console"
MGMT_CONSOLE_NAME="${SERVICE_NAME}-management-console"

# Function to extract value from JSON response
extract_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\":[^,}]*" | cut -d':' -f2- | tr -d '"' | tr -d ' '
}

# Function to get Keycloak access token
get_token() {
    echo "Attempting to get token from: https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token"
    
    TOKEN_RESPONSE=$(curl -s -k -X POST "https://${KEYCLOAK_BASE_URL}/auth/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${ADMIN_USERNAME}" \
      -d "password=${ADMIN_PASSWORD}" \
      -d "grant_type=password" \
      -d "client_id=admin-cli")

    echo "Token response: $TOKEN_RESPONSE"

    TOKEN=$(extract_json_value "$TOKEN_RESPONSE" "access_token")

    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
      echo "Failed to obtain access token. Check your credentials and Keycloak configuration."
      echo "Response from Keycloak:"
      echo "$TOKEN_RESPONSE"
      exit 1
    fi
    
    echo "Successfully obtained access token"
}

# Function to update client configuration
update_client_config() {
    # Get client configuration
    echo "Fetching clients from realm $REALM..."
    CLIENTS_RESPONSE=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${REALM}/clients" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json")

    # Debug: Print the full response
    echo "Debug - Full response:"
    echo "$CLIENTS_RESPONSE"

    # Use a simpler grep pattern first to find the client
    echo "Looking for client with ID: $CLIENT_ID"
    CLIENT_OBJECT=$(echo "$CLIENTS_RESPONSE" | tr ',' '\n' | tr '}' '\n' | grep -B5 -A5 "\"clientId\":\"$CLIENT_ID\"")
    
    echo "Found client object:"
    echo "$CLIENT_OBJECT"

    # Extract the ID from the client object
    CLIENT_ID_INTERNAL=$(echo "$CLIENT_OBJECT" | grep '"id"' | cut -d'"' -f4)

    if [ -z "$CLIENT_ID_INTERNAL" ]; then
        echo "Client ${CLIENT_ID} not found in realm ${REALM}."
        echo "Available clients:"
        echo "$CLIENTS_RESPONSE" | grep -o '"clientId":"[^"]*"' | cut -d'"' -f4
        exit 1
    fi

    echo "Found client ID for $CLIENT_ID: $CLIENT_ID_INTERNAL"

    # Get current client configuration
    CURRENT_CLIENT=$(curl -s -k -X GET "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_INTERNAL}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json")

    # Extract current redirectUris and webOrigins
    CURRENT_REDIRECTS=$(echo "$CURRENT_CLIENT" | grep -o '"redirectUris":\[[^]]*\]' | sed 's/"redirectUris":\[//;s/\]//')
    CURRENT_ORIGINS=$(echo "$CURRENT_CLIENT" | grep -o '"webOrigins":\[[^]]*\]' | sed 's/"webOrigins":\[//;s/\]//')

    # Create new redirect URI and web origin using the namespaced console name
    NEW_REDIRECT_URI="https://${TASK_CONSOLE_NAME}-${NAMESPACE}.$BASE_URL/*"
    NEW_WEB_ORIGIN="https://${TASK_CONSOLE_NAME}-${NAMESPACE}.$BASE_URL"

    echo "Adding redirect URI: $NEW_REDIRECT_URI"
    echo "Adding web origin: $NEW_WEB_ORIGIN"

    # Function to add new value to JSON array if it doesn't exist
    add_to_array() {
        local current="$1"
        local new="$2"
        if [[ $current == *"\"$new\""* ]]; then
            echo "$current"
        else
            if [ -z "$current" ]; then
                echo "\"$new\""
            else
                echo "$current,\"$new\""
            fi
        fi
    }

    # Update arrays with new values
    UPDATED_REDIRECTS=$(add_to_array "$CURRENT_REDIRECTS" "$NEW_REDIRECT_URI")
    UPDATED_ORIGINS=$(add_to_array "$CURRENT_ORIGINS" "$NEW_WEB_ORIGIN")

    # Create update payload
    UPDATE_PAYLOAD="{
        \"publicClient\": true,
        \"directAccessGrantsEnabled\": true,
        \"standardFlowEnabled\": true,
        \"implicitFlowEnabled\": false,
        \"serviceAccountsEnabled\": false,
        \"redirectUris\": [$UPDATED_REDIRECTS],
        \"webOrigins\": [$UPDATED_ORIGINS]
    }"

    echo "Updating client configuration with payload: $UPDATE_PAYLOAD"
    
    RESPONSE=$(curl -s -k -X PUT "https://${KEYCLOAK_BASE_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_INTERNAL}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${UPDATE_PAYLOAD}")

    if [ -z "$RESPONSE" ]; then
        echo "Client configuration updated successfully."
    else
        echo "Failed to update client configuration. Response: ${RESPONSE}"
        exit 1
    fi
}

# Execute Keycloak configuration before deployment
echo "Configuring Keycloak..."
get_token
update_client_config

# Delete existing deployments if they exist
oc delete deployment $SERVICE_NAME --ignore-not-found=true
oc delete deployment $TASK_CONSOLE_NAME --ignore-not-found=true
oc delete deployment $MGMT_CONSOLE_NAME --ignore-not-found=true

# Build and deploy the application
mvn clean package \
    -Dquarkus.container-image.build=true \
    -Dquarkus.kubernetes-client.namespace=$NAMESPACE \
    -Dquarkus.openshift.deploy=true \
    -Dquarkus.openshift.expose=true \
    -Dquarkus.application.name=$SERVICE_NAME \
    -Dkogito.service.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL \
    -Dkogito.jobs-service.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL \
    -Dkogito.dataindex.http.url=https://$SERVICE_NAME-$NAMESPACE.$BASE_URL

# Get the route host
ROUTE_HOST=$(oc get route $SERVICE_NAME -o jsonpath='{.spec.host}')

# Set environment variables
oc set env deployment/$SERVICE_NAME \
    KOGITO_SERVICE_URL=https://$ROUTE_HOST \
    KOGITO_JOBS_SERVICE_URL=https://$ROUTE_HOST \
    KOGITO_DATAINDEX_HTTP_URL=https://$ROUTE_HOST

# Patch the route for edge TLS termination
oc patch route $SERVICE_NAME -p '{"spec":{"tls":{"termination":"edge"}}}'

# Deploy Task Console
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TASK_CONSOLE_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $TASK_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $TASK_CONSOLE_NAME
    spec:
      containers:
      - name: task-console
        image: quay.io/bamoe/task-console:9.1.0-ibm-0001
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE
          value: "PROD"
        - name: RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "$CLIENT_ID"
---
apiVersion: v1
kind: Service
metadata:
  name: $TASK_CONSOLE_NAME
spec:
  selector:
    app: $TASK_CONSOLE_NAME
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $TASK_CONSOLE_NAME
spec:
  to:
    kind: Service
    name: $TASK_CONSOLE_NAME
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF

# Deploy Management Console
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MGMT_CONSOLE_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $MGMT_CONSOLE_NAME
  template:
    metadata:
      labels:
        app: $MGMT_CONSOLE_NAME
    spec:
      containers:
      - name: management-console
        image: quay.io/bamoe/management-console:9.1.0-ibm-0001
        ports:
        - containerPort: 8080
        env:
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_KOGITO_ENV_MODE
          value: "DEV"
        - name: RUNTIME_TOOLS_MANAGEMENT_CONSOLE_DATA_INDEX_ENDPOINT
          value: "https://$ROUTE_HOST/graphql"
        - name: KOGITO_CONSOLES_KEYCLOAK_HEALTH_CHECK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth/realms/$REALM/.well-known/openid-configuration"
        - name: KOGITO_CONSOLES_KEYCLOAK_URL
          value: "https://${KEYCLOAK_BASE_URL}/auth"
        - name: KOGITO_CONSOLES_KEYCLOAK_REALM
          value: "$REALM"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_ID
          value: "management-console"
        - name: KOGITO_CONSOLES_KEYCLOAK_CLIENT_SECRET
          value: fBd92XRwPlWDt4CSIIDHSxbcB1w0p3jm
---
apiVersion: v1
kind: Service
metadata:
  name: $MGMT_CONSOLE_NAME
spec:
  selector:
    app: $MGMT_CONSOLE_NAME
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $MGMT_CONSOLE_NAME
spec:
  to:
    kind: Service
    name: $MGMT_CONSOLE_NAME
  port:
    targetPort: 8080
  tls:
    termination: edge
EOF

echo "Deployment completed. Application is available at https://$ROUTE_HOST/q/swagger-ui"
echo "Task Console is available at https://$(oc get route $TASK_CONSOLE_NAME -o jsonpath='{.spec.host}')"
echo "Management Console is available at https://$(oc get route $MGMT_CONSOLE_NAME -o jsonpath='{.spec.host}')"