#!/usr/bin/env python3
"""Start an isolated Unix-socket PostgreSQL, never connect to a configured DB."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def concurrency_checks(psql, env):
    def sql(statement):
        return subprocess.run([*psql, '-Atq', '-c', statement], env=env,
                              check=True, text=True, capture_output=True).stdout.strip()

    def concurrent(statement, label, during):
        child = subprocess.Popen([*psql, '-Atq', '-c',
                                  f"SET application_name='{label}'; {statement}"],
                                 env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Observe a real acquired transaction/row lock before racing the other
            # connection. There is no remote DB or arbitrary timing assumption.
            for _ in range(100):
                if sql(f"SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='{label}' AND wait_event='PgSleep')") == 't':
                    break
                if child.poll() is not None:
                    raise AssertionError('locking connection ended before observation')
                time.sleep(0.01)
            else:
                raise AssertionError('locking transaction did not become ready')
            during()
            _, error = child.communicate(timeout=10)
            if child.returncode:
                raise AssertionError(error)
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    first = '00000000-0000-4000-8000-000000000011'
    second = '00000000-0000-4000-8000-000000000012'
    for identifier in (first, second):
        sql(f"INSERT INTO auth.users(id) VALUES ('{identifier}'); "
            f"INSERT INTO auth.identities(user_id,provider,provider_id) VALUES ('{identifier}','apple','concurrent-{identifier}');")

    concurrent(f"BEGIN; SELECT public.apple_store_tokens('{first}','concurrent-{first}','test-client','synthetic-cipher','test-v1'); "
               "SELECT pg_sleep(0.5); COMMIT;", 'token_capture_test',
               lambda: sql(f"SET request.jwt.claim.sub='{first}'; SELECT public.delete_user_account();"))
    assert sql(f"SELECT count(*) FROM private.apple_revoke_jobs WHERE user_id='{first}'") == '1'
    assert sql(f"SELECT count(*) FROM auth.users WHERE id='{first}'") == '0'

    def late_capture():
        result = subprocess.run([*psql, '-Atq', '-c',
                                 f"SELECT public.apple_store_tokens('{second}','concurrent-{second}','test-client','synthetic-late','test-v1');"],
                                env=env, text=True, capture_output=True)
        assert result.returncode != 0 and 'Account no longer exists' in result.stderr

    concurrent(f"BEGIN; SELECT id FROM auth.users WHERE id='{second}' FOR UPDATE; "
               f"SELECT pg_sleep(0.5); DELETE FROM auth.users WHERE id='{second}'; COMMIT;",
               'identity_delete_test', late_capture)
    assert sql(f"SELECT count(*) FROM private.apple_tokens WHERE user_id='{second}'") == '0'

    # The second worker must skip the first worker's locked job and claim the
    # other one immediately, rather than block or claim the same ciphertext.
    sql(f"INSERT INTO private.apple_revoke_jobs(user_id,apple_sub,client_id,encrypted_tokens,key_id) "
        f"VALUES ('{first}','test-sub','test-client','synthetic-two','test-v1');")
    claimed = []
    concurrent(f"BEGIN; SELECT id FROM public.apple_claim_revoke_jobs('{first}',1); SELECT pg_sleep(0.5); COMMIT;",
               'worker_claim_test',
               lambda: claimed.append(sql(f"SELECT count(*) FROM public.apple_claim_revoke_jobs('{first}',1)")))
    assert claimed == ['1']
    assert sql(f"SELECT sum(attempts) FROM private.apple_revoke_jobs WHERE user_id='{first}'") == '2'
    print('Three real concurrent PostgreSQL race checks passed.')


def main():
    binaries = {name: shutil.which(name) for name in ('initdb', 'pg_ctl', 'psql')}
    if not all(binaries.values()):
        raise SystemExit('Local PostgreSQL initdb, pg_ctl and psql are required.')
    # Do not inherit a remote PGHOST, service definition or credential.
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    with tempfile.TemporaryDirectory(prefix='account-deletion-tests-') as temp:
        directory = Path(temp)
        data = directory / 'data'
        run = lambda args, **kwargs: subprocess.run(args, env=env, check=True, text=True, **kwargs)
        run([binaries['initdb'], '-D', str(data), '--auth=trust', '--no-locale'], capture_output=True)
        started = False
        try:
            run([binaries['pg_ctl'], '-D', str(data), '-l', str(directory / 'server.log'), '-o',
                 f"-F -k {temp} -c listen_addresses=''", '-w', 'start'], capture_output=True)
            started = True
            psql = [binaries['psql'], '-X', '-h', temp, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
            for script in (ROOT / 'tests/account_deletion_fixture.sql',
                           ROOT / 'migrations/20261029113000_account_deletion_cleanup.sql',
                           ROOT / 'tests/account_deletion_test.sql'):
                result = run([*psql, '-q', '-f', str(script)], capture_output=True)
                if script.name.endswith('_test.sql'):
                    print('Account deletion SQL regression checks passed.')
            concurrency_checks(psql, env)
        except subprocess.CalledProcessError as error:
            print(error.stdout or '')
            print(error.stderr or '')
            raise SystemExit(error.returncode)
        finally:
            if started:
                run([binaries['pg_ctl'], '-D', str(data), '-m', 'immediate', '-w', 'stop'], capture_output=True)


if __name__ == '__main__':
    main()
