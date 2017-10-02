# nginx + gunicorn socket queuing issue

Reproducing `connect() to unix:/run/gunicorn.socket failed (11: Resource temporarily unavailable)` (`502` from a client's prespective) nginx error when connecting to a gunicorn upstream over unix sockets.

## Reproducing the issue

We can easily reproduce the issue using a load testing tool such as [vegeta](https://github.com/tsenart/vegeta) or [ab](https://httpd.apache.org/docs/2.4/programs/ab.html) against the provided docker container which exposes a basic gunicorn + nginx config pointing to a [Python WSGI application](./docker/root/etc/service/wsgi/server) simulating blocking I/O by calling `time.sleep` for 2 seconds / request.

First build the image and start the container:

    $ docker build -f Dockerfile -t nginx-gunicorn-reproduction .
    $ docker run -p 6789:80 -it nginx-gunicorn-reproduction:latest

Then run the load test (here with vegeta):

    $ echo "GET http://localhost:6789/" | vegeta attack -insecure -rate=10 -timeout=500s -duration=1s | vegeta report
    Requests      [total, rate]            10, 11.11
    Duration      [total, attack, wait]    20.078919479s, 899.999894ms, 19.178919585s
    Latencies     [mean, 50, 95, 99, max]  10.590887333s, 9.633994005s, 17.271007291s, 17.271007291s, 19.178919585s
    Bytes In      [total, mean]            20, 2.00
    Bytes Out     [total, mean]            0, 0.00
    Success       [ratio]                  100.00%
    Status Codes  [code:count]             200:10
    Error Set:

    $ echo "GET http://localhost:6789/" | vegeta attack -insecure -rate=200 -timeout=500s -duration=1s | vegeta report
    Requests      [total, rate]            200, 201.01
    Duration      [total, attack, wait]    34.123554433s, 994.999821ms, 33.128554612s
    Latencies     [mean, 50, 95, 99, max]  11.219240117s, 8.863828284s, 30.512506023s, 32.477038649s, 33.463554612s
    Bytes In      [total, mean]            11857, 59.28
    Bytes Out     [total, mean]            0, 0.00
    Success       [ratio]                  66.50%
    Status Codes  [code:count]             502:67  200:133
    Error Set:
    502 Bad Gateway 

By tweaking the numbers you should see that the `502`s appear almost as soon as the test start (once the socket capacity as been filled) once the number of concurrent request is higher that `129` (TCP socket queue size + 1 for wsgi worker). The docker logs should start emitting  entries similar to:

    [error] 14#14: *267 connect() to unix:/run/gunicorn.socket failed (11: Resource temporarily unavailable) while connecting to upstream, client: 172.17.0.1, server: _, request: "GET / HTTP/1.1", upstream: "http://unix:/run/gunicorn.socket:/", host: "localhost:6789"

You can easily see the solution discussed below by running the container with increased `net.core.somaxconn`:

    $ docker run -p 6789:80 --sysctl net.core.somaxconn=1024 -it nginx-gunicorn-reproduction:latest

and re-running the previous test:

    $ echo "GET http://localhost:6789/" | vegeta attack -insecure -rate=200 -timeout=500s -duration=1s | vegeta report
    Requests      [total, rate]            200, 201.01
    Duration      [total, attack, wait]    6m41.170323368s, 994.999822ms, 6m40.175323546s
    Latencies     [mean, 50, 95, 99, max]  3m21.101706787s, 3m20.101425675s, 6m20.157725671s, 6m36.172552918s, 6m40.175323546s
    Bytes In      [total, mean]            400, 2.00
    Bytes Out     [total, mean]            0, 0.00
    Success       [ratio]                  100.00%
    Status Codes  [code:count]             200:200
    Error Set:


**Note:** If you tweak the example configurations, some `504 Gateway Timeout` might appear as well in case the queued requests take too much time to respond.


## Problem & Solution

After looking into the issue for a while, we were tipped of the actual problem by reading through the gunicorn docs and [this part](http://docs.gunicorn.org/en/stable/faq.html?highlight=somaxconn#how-can-i-increase-the-maximum-socket-backlog) about needing to increase `somaxconn` to increase the backlog size. When using nginx as a reverse proxy in front of a wsgi server (here gunicorn) through a unix socket, the unix socket connection queue becomes the bottleneck regardless of nginx and / or gunicorn connection backlog capacity. As far as we understand it, nginx will hand over the request to the socket which when the queue is full will just not accept requests and nginx will consider the request failed and answer with a `502 (Bad Gateway)` as it cannot connect to the upstream, essentially resulting in dropped requests. The number of workers (nginx or gunicorn) doesn't help as everything goes through the same socket

The unix socket connection queue size can be tweaked through the `net.core.somaxconn` kernel setting which is set to `128` by default in docker containers and on Amazon's Ubuntu AMIs.

To increase `net.core.somaxconn` run one of the following command with appropriate permissions:

- `echo 'net.core.somaxconn=...' >>> /etc/sysctl.conf && sysctl -p`
- `sysctl -w net.core.somaxconn=...`
- When running inside docker containers, you need to call `docker run` with the `--sysctl net.core.somaxconn=...` flag. See https://docs.docker.com/engine/reference/commandline/run/#configure-namespaced-kernel-parameters-sysctls-at-runtime.

**Notes:**  

- In the example configuration, any setting higher than `1024` would be useless in practice as both nginx and gunicorn are set to queue up to `1024` connections. As always, tweak the settings according to you own need.

- The problem should also manifest when running gunicorn behind HTTP with a delay depending on nginx [proxy_connect_timeout](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_connect_timeout) or [proxy_read_timeout](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_read_timeout) and `504` instead of `502` status code. The nginx log should emity entries similar to:
      
        [error] 14#14: *267 upstream timed out (110: Operation timed out) while reading response header from upstream, client: 172.17.0.1, server: _, request: "GET / HTTP/1.1", upstream: "http://unix:/run/gunicorn.socket/", host: "localhost:6789"

- The problem described should only affect high concurrency servers and / or applications which are expected to wait on blocking I/O (in our case long running reporting requests). In general a higher setting should not be a problem for most applications with fast transactions but increasing the TCP queue size could hide some latency issues and failing early may be better for such cases. As always consider your specific use-case and whether this is an unavoidable problem to be solved or a symptom of a deeper issue (design, architecture, etc.).

## Further reading

- Some background on TCP socket: http://veithen.github.io/2014/01/01/how-tcp-backlog-works-in-linux.html
- Netflix write-ups on configuring Linux servers:
  - https://www.slideshare.net/AmazonWebServices/pfc306-performance-tuning-amazon-ec2-instances-aws-reinvent-2014
  - http://www.brendangregg.com/blog/2015-03-03/performance-tuning-linux-instances-on-ec2.html
- Some more write-ups on nginx specific configuration: 
  - https://www.linode.com/docs/web-servers/nginx/configure-nginx-for-optimized-performance/
  - http://engineering.chartbeat.com/2014/01/02/part-1-lessons-learned-tuning-tcp-and-nginx-in-ec2/
