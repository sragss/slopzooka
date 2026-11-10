import hashlib
import http.client
import json
from pathlib import Path
import tempfile
import sys
import time
import unittest
from unittest.mock import patch
import probe

class ClientTests(unittest.TestCase):
    def test_pin_checked_before_authentication(self):
        class Connection:
            sent=False
            closed=False
            sock=None
            def __init__(self,*args,**kwargs): self.sock=self
            def connect(self): pass
            def getpeercert(self,**kwargs): return b'wrong certificate'
            def request(self,*args,**kwargs): Connection.sent=True
            def close(self): Connection.closed=True
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'connection.json'
            path.write_text(json.dumps(dict(host='127.0.0.1',port=1,token='private',fingerprint=hashlib.sha256(b'expected').hexdigest())))
            with patch('probe.http.client.HTTPSConnection',Connection):
                with self.assertRaisesRegex(RuntimeError,'credentials not sent'): probe.Client(path).status()
        self.assertFalse(Connection.sent)
        self.assertTrue(Connection.closed)

    def test_budget_reserves_cleanup_time(self):
        client=probe.Client.__new__(probe.Client)
        client.status=lambda:dict(armed=True,remainingSeconds=12)
        self.assertEqual(client.budget(100)[0],7)
        client.status=lambda:dict(armed=True,remainingSeconds=4)
        with self.assertRaises(RuntimeError): client.budget()

    def test_driver_cannot_be_redirected_to_external_host(self):
        for url in ['https://127.0.0.1','http://example.com','http://x@127.0.0.1','http://127.0.0.1/not-root']:
            with self.assertRaises(ValueError): probe.driver_request(url,'GET','/status')

    def test_manual_session_keeps_individual_operation_limit(self):
        client=probe.Client.__new__(probe.Client)
        client.status=lambda:dict(armed=True,untilStopped=True,remainingSeconds=None)
        self.assertEqual(client.budget(15)[0],15)
        client.status=lambda:dict(armed=False,untilStopped=True,remainingSeconds=None)
        with self.assertRaises(RuntimeError): client.budget(15)

    def test_timeout_cleans_up_owned_child(self):
        with tempfile.TemporaryDirectory() as folder:
            pidfile=Path(folder)/'pid'
            # Only our short-lived non-GUI child. No simulator, app, network, or desktop effects.
            script='import os, pathlib, time; pathlib.Path(__import__("sys").argv[1]).write_text(str(os.getpid())); time.sleep(20)'
            started=time.monotonic()
            with self.assertRaises(TimeoutError):
                probe.bounded([sys.executable,'-c',script,str(pidfile)],.4,Path(folder)/'log')
            self.assertLess(time.monotonic()-started,4)
            with self.assertRaises(ProcessLookupError): probe.os.kill(int(pidfile.read_text()),0)

    def test_stop_cleanup_runs_before_termination(self):
        called=[]
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(TimeoutError):
                probe.bounded([sys.executable,'-c','import time; time.sleep(20)'],.2,Path(folder)/'log',before_stop=lambda:called.append(True))
        self.assertEqual(called,[True])

if __name__=='__main__': unittest.main()
