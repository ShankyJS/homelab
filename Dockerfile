FROM python:3.12-slim

# Install system deps for Ansible SSH connections
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    sshpass \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible (pin ansible-core<2.18 for Python 3.8 target support on Ubuntu 20.04)
# TODO: remove pin after reflashing Jetson to JetPack 6 / Ubuntu 22.04
RUN pip install --no-cache-dir \
    'ansible-core>=2.17,<2.18' \
    ansible \
    ansible-lint

WORKDIR /ansible
COPY ansible/requirements.yml /ansible/requirements.yml

# Install Ansible collections
RUN ansible-galaxy collection install -r requirements.yml

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /ansible
ENTRYPOINT ["entrypoint.sh"]
