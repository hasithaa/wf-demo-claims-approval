# A curl-and-jq one-shot for first-boot seeding. Alpine keeps it tiny.
FROM alpine:3.20
RUN apk add --no-cache curl jq
COPY seed.sh /seed.sh
RUN chmod +x /seed.sh
ENTRYPOINT ["/seed.sh"]
