#!/bin/sh
# Secrets are passed as env vars from the Makefile (sourced from 1Password CLI or CI env).
# No vault files needed.
exec ansible-playbook "$@"
