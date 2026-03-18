#!/bin/bash
set -e

cd "$(dirname "$0")"

# ---- Config (override via env vars) ----
DB_USER="${MM_DB_USER:-mmuser}"
DB_PASS="${MM_DB_PASS:-mmuser_password}"
DB_NAME="${MM_DB_NAME:-mattermost}"
DB_HOST="${MM_DB_HOST:-localhost}"
DB_PORT="${MM_DB_PORT:-5432}"
SITE_URL="${MM_SERVICESETTINGS_SITEURL:-http://localhost:8065}"
USER_LIMIT="${MM_SYNTHETIC_USER_LIMIT:-10}"
USER_LIMIT_EXTRA="${MM_SYNTHETIC_USER_LIMIT_EXTRA:-5}"
GO_VERSION="1.24.13"
NODE_VERSION="24"

echo "============================================"
echo "  Mattermost Full Setup & Run"
echo "============================================"
echo ""

# ---- 1. Install prerequisites ----
echo "==> Installing prerequisites..."

# Go
if ! command -v go &>/dev/null || ! go version | grep -q "go${GO_VERSION}"; then
    echo "    Installing Go ${GO_VERSION}..."
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    export PATH="/usr/local/go/bin:$PATH"
    echo "    Go $(go version) installed."
else
    echo "    Go already installed: $(go version)"
fi
export PATH="/usr/local/go/bin:$(go env GOPATH)/bin:$PATH"

# Node.js
if ! command -v node &>/dev/null || ! node -v | grep -q "^v${NODE_VERSION}\."; then
    echo "    Installing Node.js ${NODE_VERSION}.x..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo "    Node $(node -v) installed."
else
    echo "    Node already installed: $(node -v)"
fi

# Build tools
echo "    Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential git

# PostgreSQL
if ! command -v psql &>/dev/null; then
    echo "    Installing PostgreSQL..."
    sudo apt-get install -y -qq postgresql postgresql-contrib
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
    echo "    PostgreSQL installed and started."
else
    echo "    PostgreSQL already installed."
    sudo systemctl start postgresql 2>/dev/null || true
fi

# ---- 2. Setup database ----
echo ""
echo "==> Setting up database..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
echo "    Database ready: ${DB_NAME}"

# ---- 3. Build webapp ----
echo ""
echo "==> Building webapp (this may take a few minutes)..."
cd webapp
npm install
npm run build
cd ..

# ---- 4. Build server ----
echo ""
echo "==> Building server..."
cd server
make setup-go-work
go build -tags sourceavailable -o bin/mattermost ./cmd/mattermost
go build -o bin/mmctl ./cmd/mmctl

# ---- 5. Link webapp ----
echo "==> Linking webapp..."
ln -nfs ../webapp/channels/dist client
mkdir -p client/files

# ---- 6. Start server ----
echo ""
echo "============================================"
echo "  Starting Mattermost"
echo "============================================"
export MM_SQLSETTINGS_DRIVERNAME=postgres
export MM_SQLSETTINGS_DATASOURCE="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
export MM_SERVICESETTINGS_SITEURL="$SITE_URL"
export MM_SERVICESETTINGS_LISTENADDRESS=":8065"
export MM_SYNTHETIC_USER_LIMIT="$USER_LIMIT"
export MM_SYNTHETIC_USER_LIMIT_EXTRA="$USER_LIMIT_EXTRA"

echo ""
echo "  Site URL:    $SITE_URL"
echo "  DB:          ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "  User limit:  $USER_LIMIT (+$USER_LIMIT_EXTRA grace)"
echo ""
echo "  Open $SITE_URL in your browser to complete setup."
echo ""

exec ./bin/mattermost
