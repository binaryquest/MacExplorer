import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/release'))
from stapler import run_stapler


# The diagnostic emitted by Apple's ticket service during the 0.11.2 release.
CONNECTION_LOST = '''error is Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."
NSErrorFailingURLStringKey=https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup
CloudKit's response is inconsistent with expections: (null)
The validate action failed! Error 68.
'''


def result(code, output=''):
    return subprocess.CompletedProcess([], code, stdout=output)


class StaplerTests(unittest.TestCase):
    def invoke(self, responses, action='validate', path='/tmp/Explorer.app'):
        output = io.StringIO()
        with patch('stapler.subprocess.run', side_effect=responses) as run, \
             patch('stapler.time.sleep') as sleep, contextlib.redirect_stdout(output):
            status = run_stapler(action, path)
        return status, run, sleep, output.getvalue()

    def test_connection_loss_recovers_for_both_operations_without_changing_path(self):
        path = "/tmp/Space & Quote's $(literal)/日本語/Explorer.app"
        for action in ['staple', 'validate']:
            with self.subTest(action=action):
                status, run, sleep, output = self.invoke([result(68, CONNECTION_LOST), result(0, 'Success\n')], action, path)
                self.assertEqual(status, 0)
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args_list[0], run.call_args_list[1])
                self.assertEqual(run.call_args.args[0], ['xcrun', 'stapler', action, path])
                self.assertEqual(run.call_args.kwargs['timeout'], 120)
                sleep.assert_called_once_with(10)
                self.assertIn(CONNECTION_LOST, output)
                self.assertIn('attempt 2/5', output)

    def test_persistent_network_failure_is_bounded_and_remains_fatal(self):
        status, run, sleep, output = self.invoke([result(68, CONNECTION_LOST)] * 5)
        self.assertEqual(status, 68)
        self.assertEqual(run.call_count, 5)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [10, 20, 40, 80])
        self.assertIn('retries exhausted', output)

    def test_other_transient_transport_failures_recover(self):
        for code in [-1001, -1003, -1004, -1006, -1009]:
            with self.subTest(code=code):
                status, run, sleep, _ = self.invoke([result(68, f'Error Domain=NSURLErrorDomain Code={code}'), result(0)])
                self.assertEqual(status, 0)
                self.assertEqual(run.call_count, 2)
                sleep.assert_called_once_with(10)

    def test_validation_and_unknown_errors_fail_immediately(self):
        failures = [
            (65, 'The ticket data is invalid.'),
            (66, 'The existing ticket is missing or invalid.'),
            (77, 'The ticket has been revoked.'),
            (68, 'Record not found. The path has not been previously notarized.'),
            (68, 'Unexpected response from ticket service.'),
            (68, 'Error Domain=NSURLErrorDomain Code=-1200 "TLS failure"'),
            (68, 'Error Domain=NSURLErrorDomain Code=-1013 "Authentication required"'),
            (68, 'Error Domain=NSURLErrorDomain Code=-10050'),
            (68, CONNECTION_LOST + 'Error Domain=NSURLErrorDomain Code=-1200'),
            (65, CONNECTION_LOST),
        ]
        for code, diagnostic in failures:
            with self.subTest(code=code, diagnostic=diagnostic):
                status, run, sleep, output = self.invoke([result(code, diagnostic)])
                self.assertEqual(status, code)
                run.assert_called_once()
                sleep.assert_not_called()
                self.assertIn(diagnostic, output)

    def test_success_does_not_retry_warning_diagnostics(self):
        status, run, sleep, _ = self.invoke([result(0, CONNECTION_LOST)])
        self.assertEqual(status, 0)
        run.assert_called_once()
        sleep.assert_not_called()

    def test_command_timeout_can_recover_but_persistent_timeouts_fail(self):
        timeout = subprocess.TimeoutExpired(['xcrun'], 120, output=b'Partial output\n')
        status, run, sleep, output = self.invoke([timeout, result(0)])
        self.assertEqual(status, 0)
        sleep.assert_called_once_with(10)
        self.assertIn('Partial output', output)
        self.assertIn('120-second command timeout', output)
        status, run, sleep, output = self.invoke([timeout] * 5)
        self.assertEqual(status, 124)
        self.assertEqual(run.call_count, 5)
        self.assertEqual(sleep.call_count, 4)
        self.assertIn('retries exhausted', output)

    def test_permanent_failure_after_transport_error_stops_retries(self):
        status, run, sleep, _ = self.invoke([result(68, CONNECTION_LOST), result(77, 'Ticket revoked')])
        self.assertEqual(status, 77)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(10)

    def test_terminated_command_fails_without_retry(self):
        status, run, sleep, _ = self.invoke([result(-15)])
        self.assertEqual(status, 143)
        run.assert_called_once()
        sleep.assert_not_called()


if __name__ == '__main__':
    unittest.main()
