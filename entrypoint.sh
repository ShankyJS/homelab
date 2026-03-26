#!/bin/sh
# If VAULT_PASSWORD env var is set, create a vault password script
if [ -n "$VAULT_PASSWORD" ]; then
    printf '#!/bin/sh\nprintf "%%s" "$VAULT_PASSWORD"\n' > /tmp/vault-pass-env.sh
    chmod +x /tmp/vault-pass-env.sh
fi

exec ansible-playbook "$@"
