#!/usr/bin/env python3
"""Profile local app builds using disposable runner fixtures, without GitHub access."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


def cpu_snapshot(pid):
    fields = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time=,rss='], text=True, timeout=5).split()
    if len(fields) != 2:
        raise RuntimeError('Test app exited before measurement completed')
    cpu = sum(float(part) * 60 ** power for power, part in enumerate(reversed(fields[0].split(':'))))
    return cpu, int(fields[1]) / 1024


def profile(app, fixture, root, label, seconds, window, sample_directory):
    bundle = root / f'{label}.app'
    shutil.copytree(app, bundle, symlinks=True)
    plist_path = bundle / 'Contents/Info.plist'
    metadata = plistlib.loads(plist_path.read_bytes())
    metadata['CFBundleIdentifier'] = f'com.kostarelas.RunnerMenu.PerformanceAudit.{label}'
    metadata['SUPublicEDKey'] = ''
    plist_path.write_bytes(plistlib.dumps(metadata))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    directories = sorted(fixture.glob('runner-*'))
    argument_array = '(' + ','.join('"' + str(path).replace('"', '\\"') + '"' for path in directories) + ')'
    previous_probes = [probes(path) for path in directories]
    environment = dict(os.environ)
    if window:
        environment['RUNNERMENU_OPENWINDOW'] = '1'
    else:
        environment.pop('RUNNERMENU_OPENWINDOW', None)
    environment.pop('RUNNERMENU_DOCK', None)
    console = root / f'{label}.log'
    with console.open('wb') as stream:
        process = subprocess.Popen([str(bundle / 'Contents/MacOS/RunnerMenu'),
                                    '-runnerDirectories', argument_array,
                                    '-ghPath', str(root / 'gh-fixture'),
                                    '-runnerOnboardingCompleted', 'YES'],
                                   env=environment, stdout=stream, stderr=stream)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f'{label}: app exited during startup')
                observed = [probes(path) - previous for path, previous in zip(directories, previous_probes)]
                loaded = sum(observed)
                if all(count > 0 for count in observed):
                    break
                time.sleep(.2)
            else:
                raise RuntimeError(f'{label}: configured fixtures were not observed; refusing an invalid CPU comparison')
            # Exclude startup and version checks, while allowing multiple status polls.
            time.sleep(5)
            cpu_before, _ = cpu_snapshot(process.pid)
            start = time.monotonic()
            memories = []
            while time.monotonic() - start < seconds:
                time.sleep(min(2, max(.1, seconds - (time.monotonic() - start))))
                cpu_after, memory = cpu_snapshot(process.pid)
                memories.append(memory)
            elapsed = time.monotonic() - start
            result = {'cpu_percent': round(100 * (cpu_after - cpu_before) / elapsed, 3),
                      'cpu_seconds': round(cpu_after - cpu_before, 3),
                      'measurement_seconds': round(elapsed, 2),
                      'max_sampled_rss_mb': round(max(memories), 2),
                      'startup_version_probes': loaded,
                      'runners_observed_before_measurement': sum(count > 0 for count in observed),
                      'configured_runners': len(directories),
                      'main_window_requested': window}
            print(json.dumps({'completed': label, **result}), flush=True)
            if window and sample_directory:
                sample_directory.mkdir(parents=True, exist_ok=True)
                destination = sample_directory / f'{label}.sample.txt'
                try:
                    subprocess.run(['sample', str(process.pid), '3', '-file', str(destination)],
                                   check=True, capture_output=True, timeout=15)
                    result['stack_sample_status'] = 'saved'
                except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
                    result['stack_sample_status'] = 'unavailable: ' + type(error).__name__
                    print(json.dumps({'stack_sample': result['stack_sample_status'], 'case': label}), flush=True)
            return result
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def probes(directory):
    path = directory / 'version-probes.txt'
    return len(path.read_text().splitlines()) if path.exists() else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--process-probe', type=Path, help='Compiled benchmark executable to verify the production process scanner')
    parser.add_argument('--sample-directory', type=Path, help='Save a CPU stack sample after each window measurement')
    parser.add_argument('--seconds', type=int, default=30)
    arguments = parser.parse_args()
    if not 10 <= arguments.seconds <= 60:
        parser.error('--seconds must be between 10 and 60')
    marker = arguments.fixtures / 'performance-fixture.json'
    if not marker.is_file() or json.loads(marker.read_text()) != {'purpose': 'RunnerMenu performance fixture', 'runner_count': 8}:
        parser.error('--fixtures must point to temporary fixtures created by run-performance-benchmarks.sh --keep-fixtures')
    if len(list(arguments.fixtures.glob('runner-*'))) != 8:
        parser.error('Expected exactly eight synthetic runner directories')
    root = Path(tempfile.mkdtemp(prefix='runner-menu-native-audit-'))
    processes = []
    try:
        source = root / 'fixture-runner.c'
        source.write_text('''#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        FILE *file = fopen("version-probes.txt", "a");
        if (file) { fputs("probe\\n", file); fclose(file); }
        puts("2.999.0"); return 0;
    }
    for (;;) sleep(60);
}
''')
        executable = root / 'fixture-runner'
        subprocess.run(['cc', '-O2', str(source), '-o', str(executable)], check=True)
        gh = root / 'gh-fixture'
        gh.write_text("#!/bin/sh\nif [ \"$1\" = auth ] && [ \"$2\" = status ]; then printf 'Logged in to github.com account fixture\\nActive account: true\\nToken scopes: repo\\n'; else exit 1; fi\n")
        gh.chmod(0o755)
        for directory in sorted(arguments.fixtures.glob('runner-*')):
            bin_path = directory / 'bin'
            bin_path.mkdir(exist_ok=True)
            target = bin_path / 'Runner.Listener'
            shutil.copy2(executable, target)
            processes.append(subprocess.Popen([str(target)], cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        # A busy runner exercises the live status path without executing any jobs.
        busy = sorted(arguments.fixtures.glob('runner-*'))[0]
        worker = busy / 'bin/Runner.Worker'
        shutil.copy2(executable, worker)
        processes.append(subprocess.Popen([str(worker)], cwd=busy, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        result = {'schema_version': 1, 'scope': 'Synthetic eight-runner fixtures; no GitHub requests or real runner control',
                  'cases': {}, 'system': {'macos': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
                                         'architecture': subprocess.check_output(['uname', '-m'], text=True).strip()}}
        if arguments.process_probe:
            output = subprocess.check_output([str(arguments.process_probe.resolve()), '--verify-live-processes',
                                              str(arguments.fixtures)], text=True, timeout=30)
            result['process_scan_validation'] = json.loads(output)
            print(json.dumps({'process_scan_validation': result['process_scan_validation']}), flush=True)
        builds = [('before', arguments.baseline)] if arguments.baseline else []
        builds.append(('after', arguments.app))
        for label, app in builds:
            for window in [False, True]:
                case = label + ('_window' if window else '_menu_closed')
                result['cases'][case] = profile(app.resolve(), arguments.fixtures, root, case, arguments.seconds, window,
                                              arguments.sample_directory)
                arguments.output.parent.mkdir(parents=True, exist_ok=True)
                arguments.output.write_text(json.dumps(result, indent=2) + '\n')
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            process.wait(timeout=5)
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
