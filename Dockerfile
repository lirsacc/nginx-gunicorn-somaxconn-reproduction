FROM python:3.6-alpine3.6

ENV LANG C.UTF-8
ENV TERM xterm

RUN \
  apk update && apk upgrade \
  && rm -f /var/cache/apk/*

RUN \
  apk add --update tini runit \
  && rm -rf /var/cache/apk/*

RUN \
  apk add --update nginx \
  && rm -rf /var/cache/apk/*

RUN \
  pip install --upgrade gunicorn \
  && rm -fr /.cache/pip

COPY docker/root /

RUN chmod +x /opt/run.sh
RUN mkdir -p /run

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/run.sh"]
EXPOSE 80
