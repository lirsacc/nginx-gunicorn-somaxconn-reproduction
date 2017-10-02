#!/usr/bin/env python
# encoding: utf-8

import time

def app(_, start_response):
    """ Minimal WSGI app simulating blocking I/O by calling `time.sleep` """
    time.sleep(2)
    start_response('200 OK', [('Content-Type', 'text/html')])
    return [b'OK']
