# Valkey_Testing

# Test only (Valkey already installed):
sudo bash valkey_test.sh

# Install then test (installs via your distro's package manager):
sudo bash valkey_test.sh --install

# Custom ports (e.g. Redis on 6379, Valkey on 6380):
sudo bash valkey_test.sh --redis-port 6379 --port 6380

# Save logs to a specific directory:
sudo bash valkey_test.sh --logdir /var/log/valkey_audit
