# Custom GitHub Actions Runner image with extra tools
# Built on the stock ARC runner image, adds make and build-essential
# for running Makefile-based workflows (e.g. Ansible via Docker)
FROM ghcr.io/actions/actions-runner:latest

USER root

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
        make \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

USER runner
