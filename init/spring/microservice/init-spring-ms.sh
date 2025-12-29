#!/usr/bin/env bash

# ==============================================================================
# microservices-gen.sh
#
# Description:
#   Automates the scaffolding of a Spring Boot Microservices platform.
#   Generates Discovery Server, Config Server, and API Gateway.
#   Supports Maven and Gradle build tools.
#   Initializes Git repository with appropriate .gitignore.
#
# Usage:
#   ./microservices-gen.sh [options]
#
# Options:
#   -b, --build-tool <maven|gradle>   Build tool to use (default: maven)
#   -g, --group-id <id>               Group ID for artifacts (default: com.example)
#   -v, --java-version <version>      Java version (default: 17)
#   -o, --out-dir <dir>               Root output directory (default: microservices-platform)
#   -c, --config <file>               Path to configuration file
#   --version                         Print script version
#   -h, --help                        Print this help message
#
# Inputs:
#   Internet connection required to reach https://start.spring.io
#
# Output:
#   A directory containing the scaffolded microservices architecture.
# ==============================================================================

# ------------------------------------------------------------------------------
# Best Practices & Safety
# ------------------------------------------------------------------------------
set -o errexit  # Exit on error
set -o nounset  # Exit on unset variables
set -o pipefail # Exit if any command in a pipe fails

# Trace mode if TRACE env var is set
if [[ "${TRACE-0}" == "1" ]]; then set -o xtrace; fi

# ------------------------------------------------------------------------------
# Constants & Defaults
# ------------------------------------------------------------------------------
readonly VERSION="1.2.0"
readonly SCRIPT_NAME=$(basename "$0")

# Colors for logging
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default Configuration
DEFAULT_BUILD_TOOL="maven"
DEFAULT_ROOT_DIR="microservices-platform"
DEFAULT_GROUP_ID="com.example"
DEFAULT_JAVA_VERSION="21"
DEFAULT_BOOT_VERSION="4.0.1"
DEFAULT_LANGUAGE="java"

# Initialize variables with defaults
BUILD_TOOL="${BUILD_TOOL:-$DEFAULT_BUILD_TOOL}"
ROOT_DIR="${ROOT_DIR:-$DEFAULT_ROOT_DIR}"
GROUP_ID="${GROUP_ID:-$DEFAULT_GROUP_ID}"
JAVA_VERSION="${JAVA_VERSION:-$DEFAULT_JAVA_VERSION}"
BOOT_VERSION="${BOOT_VERSION:-$DEFAULT_BOOT_VERSION}"
CONFIG_FILE=""

# ------------------------------------------------------------------------------
# Logging Functions
# ------------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; }

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
print_usage() {
  grep '^# ' "$0" | cut -c 3- | sed -n '4,19p'
}

print_version() {
  echo "$SCRIPT_NAME version $VERSION"
}

check_dependencies() {
  local dependencies=("curl" "unzip" "git")
  for cmd in "${dependencies[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command '$cmd' not found. Please install it."
      exit 1
    fi
  done
}

# Robust sed wrapper for cross-platform compatibility (Linux vs macOS)
safe_sed() {
  local expression=$1
  local file=$2
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$expression" "$file"
  else
    sed -i "$expression" "$file"
  fi
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log_info "Loading configuration from $CONFIG_FILE"
    while IFS='=' read -r key value; do
      # Strip whitespace and quotes
      key=$(echo "$key" | tr -d ' ')
      value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//')

      case $key in
      BUILD_TOOL) BUILD_TOOL="$value" ;;
      ROOT_DIR) ROOT_DIR="$value" ;;
      GROUP_ID) GROUP_ID="$value" ;;
      JAVA_VERSION) JAVA_VERSION="$value" ;;
      BOOT_VERSION) BOOT_VERSION="$value" ;;
      esac
    done <"$CONFIG_FILE"
  fi
}

# ------------------------------------------------------------------------------
# Logic Functions
# ------------------------------------------------------------------------------

download_project() {
  local name="$1"
  local dependencies="$2"
  local package_name="${GROUP_ID}.${name//-/.}"
  local project_type=""

  if [[ "$BUILD_TOOL" == "maven" ]]; then
    project_type="maven-project"
  else
    project_type="gradle-project"
  fi

  log_info "Generating project: $name ($project_type)..."

  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$name.zip" \
    https://start.spring.io/starter.zip \
    -d type="$project_type" \
    -d language="$DEFAULT_LANGUAGE" \
    -d bootVersion="$BOOT_VERSION" \
    -d baseDir="$name" \
    -d groupId="$GROUP_ID" \
    -d artifactId="$name" \
    -d name="$name" \
    -d packageName="$package_name" \
    -d javaVersion="$JAVA_VERSION" \
    -d dependencies="$dependencies")

  if [[ "$http_code" != "200" ]]; then
    log_error "Failed to download project from Spring Initializr. HTTP Code: $http_code"
    cat "$name.zip"
    rm -f "$name.zip"
    return 1
  fi

  unzip -q "$name.zip"
  rm "$name.zip"
  log_success "Created $name"
}

create_dockerfile() {
  local dir="$1"
  local jar_path=""

  if [[ "$BUILD_TOOL" == "maven" ]]; then
    jar_path="target/*.jar"
  else
    jar_path="build/libs/*.jar"
  fi

  log_info "Creating Dockerfile for $dir..."
  cat <<EOF >"$dir/Dockerfile"
FROM eclipse-temurin:${JAVA_VERSION}-jre
WORKDIR /app
COPY ${jar_path} app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
EOF
}

setup_discovery_server() {
  local service_name="discovery-server"
  download_project "$service_name" "cloud-eureka-server,actuator"

  local main_class_path="$service_name/src/main/java/${GROUP_ID//.///}/${service_name//-///}/DiscoveryServerApplication.java"

  if [[ -f "$main_class_path" ]]; then
    safe_sed '/@SpringBootApplication/a \
@EnableEurekaServer' "$main_class_path"
    safe_sed '3i \
import org.springframework.cloud.netflix.eureka.server.EnableEurekaServer;' "$main_class_path"
  else
    log_warn "Could not find main class to inject annotations at $main_class_path"
  fi

  create_dockerfile "$service_name"
}

setup_api_gateway() {
  local service_name="api-gateway"
  download_project "$service_name" "cloud-gateway,cloud-eureka,actuator"
  create_dockerfile "$service_name"
}

setup_config_server() {
  local service_name="config-server"
  download_project "$service_name" "cloud-config-server,actuator"

  local main_class_path="$service_name/src/main/java/${GROUP_ID//.///}/${service_name//-///}/ConfigServerApplication.java"

  if [[ -f "$main_class_path" ]]; then
    safe_sed '/@SpringBootApplication/a \
@EnableConfigServer' "$main_class_path"
    safe_sed '3i \
import org.springframework.cloud.config.server.EnableConfigServer;' "$main_class_path"
  fi

  mkdir -p "$service_name/config-repo"
  cat <<EOF >"$service_name/config-repo/application.yml"
server:
  port: 8888
spring:
  cloud:
    config:
      server:
        git:
          uri: \${HOME}/config-repo
EOF

  create_dockerfile "$service_name"
}

create_readme() {
  local run_cmd=""
  if [[ "$BUILD_TOOL" == "maven" ]]; then
    run_cmd="./mvnw spring-boot:run"
  else
    run_cmd="./gradlew bootRun"
  fi

  cat <<EOF >README.md
# Microservices Platform

Generated on $(date) using version $VERSION.

## Components
| Service | Description | Port |
|---------|-------------|------|
| Discovery Server | Eureka Registry | 8761 |
| Config Server | Centralized Configuration | 8888 |
| API Gateway | Entry point & Routing | 8080 |

## Build Tool
- **$BUILD_TOOL** (Java $JAVA_VERSION)

## Quick Start
1. **Start Discovery Server**:
   \`\`\`bash
   cd infra/discovery-server
   $run_cmd
   \`\`\`
2. **Start Config Server**:
   \`\`\`bash
   cd infra/config-server
   $run_cmd
   \`\`\`
3. **Start Gateway**:
   \`\`\`bash
   cd infra/api-gateway
   $run_cmd
   \`\`\`

## Docker
Build images using the generated Dockerfiles in each service directory.
EOF
}

setup_git() {
  log_info "Initializing Git repository..."

  # Create .gitignore
  cat <<EOF >.gitignore
# Created by microservices-gen.sh
# System
.DS_Store
Thumbs.db

# IDEs
.idea/
.vscode/
*.iml
.classpath
.project
.settings/

# Logs
*.log
logs/

# Java
*.class
*.jar
*.war

# Build Results
EOF

  # Build tool specific ignores
  if [[ "$BUILD_TOOL" == "maven" ]]; then
    cat <<EOF >>.gitignore
target/
mvnw
mvnw.cmd
.mvn/
EOF
  else
    cat <<EOF >>.gitignore
build/
.gradle/
gradlew
gradlew.bat
gradle/
EOF
  fi

  # Initialize and Commit
  if [ ! -d .git ]; then
    git init -q
    git add .
    git commit -q -m "Initial microservices scaffolding (Java $JAVA_VERSION, $BUILD_TOOL)"
    log_success "Git repository initialized and initial commit created."
  else
    log_warn "Git repository already exists. Skipping 'git init'."
  fi
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
  check_dependencies

  # Parse Arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      print_usage
      exit 0
      ;;
    --version)
      print_version
      exit 0
      ;;
    -b | --build-tool)
      BUILD_TOOL="$2"
      shift
      ;;
    -g | --group-id)
      GROUP_ID="$2"
      shift
      ;;
    -v | --java-version)
      JAVA_VERSION="$2"
      shift
      ;;
    -o | --out-dir)
      ROOT_DIR="$2"
      shift
      ;;
    -c | --config)
      CONFIG_FILE="$2"
      shift
      ;;
    *)
      log_error "Unknown argument: $1"
      print_usage
      exit 1
      ;;
    esac
    shift
  done

  # Load config file if provided
  if [[ -n "$CONFIG_FILE" ]]; then
    load_config
  fi

  # Validate Inputs
  if [[ "$BUILD_TOOL" != "maven" && "$BUILD_TOOL" != "gradle" ]]; then
    log_error "Invalid build tool: $BUILD_TOOL. Must be 'maven' or 'gradle'."
    exit 1
  fi

  log_info "Initializing Microservices Platform..."
  log_info "Tool: $BUILD_TOOL | Java: $JAVA_VERSION | Root: $ROOT_DIR"

  # Create Directories
  if [[ -d "$ROOT_DIR" ]]; then
    log_warn "Directory $ROOT_DIR already exists."
  fi
  mkdir -p "$ROOT_DIR"/{services,common,infra,deploy/{docker,k8s}}

  # Navigate to Root
  pushd "$ROOT_DIR" >/dev/null

  # Infrastructure Setup
  pushd infra >/dev/null
  setup_discovery_server
  setup_api_gateway
  setup_config_server
  popd >/dev/null # Back to ROOT_DIR

  # Finalize
  create_readme
  setup_git

  echo ""
  log_success "Platform setup complete at $(pwd)"
  echo "--------------------------------------------------"
  echo -e "Next steps:"
  echo -e "  1. ${YELLOW}cd $ROOT_DIR/infra/discovery-server${NC}"
  echo -e "  2. Run: ${GREEN}./mvnw spring-boot:run${NC} (or ./gradlew bootRun)"
  echo "--------------------------------------------------"
}

# Invoke main
main "$@"
