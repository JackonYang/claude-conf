# >>> claude-conf proxy >>>
# Managed by claude-conf infra/. Do not edit between markers — run `setup.sh apply`.
# Placed before any non-interactive early-return so non-interactive shells inherit proxy.
export HTTP_PROXY=http://127.0.0.1:${PROXY_PORT}
export HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT}
export http_proxy=http://127.0.0.1:${PROXY_PORT}
export https_proxy=http://127.0.0.1:${PROXY_PORT}
export NO_PROXY=localhost,127.0.0.1,::1,*.aigcic.com,gitlab-sw.aigcic.com,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8
export no_proxy=localhost,127.0.0.1,::1,*.aigcic.com,gitlab-sw.aigcic.com,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8
# <<< claude-conf proxy <<<
