
ARG KUBECTL_VERSION=v1.34.0

FROM alpine:3.22 AS kubectl

ARG KUBECTL_VERSION
ARG TARGETARCH

RUN apk add --no-cache ca-certificates curl \
    && curl -fsSLo /usr/local/bin/kubectl \
       "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 \
       "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/kubectl

FROM postgres:16-alpine

COPY --from=kubectl /usr/local/bin/kubectl /usr/local/bin/kubectl

WORKDIR /work

COPY backup.sh /work/backup.sh

RUN chmod 0755 /work/backup.sh

CMD ["/work/backup.sh"]
