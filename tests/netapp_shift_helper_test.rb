# Unit tests for NetAppShift::Helper (netapp_shift_helper.rb).
#
# Run with: ruby tests/netapp_shift_helper_test.rb
#
# netapp_shift_helper.rb has no OpenNebula dependencies, so unlike the
# oneswap_helper tests no require shims are needed. Script-backed operations
# are exercised against a stub interpreter that replays real upstream log
# messages; REST reads are exercised against stubbed api_request responses.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'logger'
require 'tmpdir'

require_relative '../netapp_shift_helper'

# Timestamped log line in the upstream scripts' format
def log_line(msg, level = 'INFO')
    "2026-08-07 10:00:00,000 - Mod - #{level} - #{msg}"
end

QUIET = Logger.new(File::NULL)

def quiet_helper(opts = {})
    NetAppShift::Helper.new({ :server   => 'https://shift.local',
                              :username => 'admin',
                              :password => 's3cr3t',
                              :logger   => QUIET }.merge(opts))
end

# Helper instance without running initialize, for parser-only tests
def bare_helper
    NetAppShift::Helper.allocate
end

class ParserTest < Minitest::Test

    def parse(op, output)
        bare_helper.send(:parse, op, output)
    end

    def test_get_site_ok
        assert parse(:get_site, log_line('Site details fetched successfully'))[:ok]
        refute parse(:get_site, log_line('Failed to fetch site details', 'ERROR'))[:ok]
    end

    def test_create_blueprint
        out  = [log_line('Blueprint created with id: bp-123'),
                log_line('Verified blueprint details: {}')].join("\n")
        data = parse(:create_blueprint, out)

        assert data[:ok]
        assert_equal 'bp-123', data[:blueprint_id]
        assert data[:verified]
        refute parse(:create_blueprint, log_line('Blueprint creation failed', 'ERROR'))[:ok]
    end

    def test_compliance
        out  = [log_line('Compliance check initiated with task id: task-9'),
                log_line("Compliance check passed with result: [{'a': 1}]")].join("\n")
        data = parse(:run_compliance_check, out)

        assert data[:ok]
        assert_equal 'task-9', data[:compliance_task_id]
    end

    def test_trigger_migration
        data = parse(:trigger_migration,
                     log_line('Migration triggered for blueprint bp_web with execution id: exec-77'))

        assert data[:ok]
        assert_equal 'exec-77', data[:execution_id]
    end

    def test_migration_status_complete
        out  = [log_line('Status of Blueprint is convert_complete for blueprint bp-1'),
                log_line('Job steps successfully completed for execution id exec-77')].join("\n")
        data = parse(:check_migration_status, out)

        assert data[:ok]
        assert_equal 'convert_complete', data[:status]
        assert data[:complete]
        refute data[:running]
    end

    def test_migration_status_error
        out  = [log_line('Status of Blueprint is convert_error for blueprint bp-1'),
                log_line('Job step Convert disks is not successful', 'ERROR')].join("\n")
        data = parse(:check_migration_status, out)

        refute data[:ok]
        refute data[:running]
        assert_equal ['Convert disks'], data[:failed_steps]
    end

    def test_migration_status_python_gave_up_means_running
        # verify_blueprint_status hit its ~20 min ceiling and returned False
        data = parse(:check_migration_status,
                     log_line('Status of Blueprint is False for blueprint bp-1'))

        refute data[:ok]
        refute data[:complete]
        assert data[:running]
    end

    def test_migration_status_no_output_means_running
        data = parse(:check_migration_status, '')

        refute data[:ok]
        assert data[:running]
    end

    def test_error_line_extraction
        out = [log_line('all good'),
               log_line('Failed to create blueprint, Response code is 500', 'ERROR'),
               log_line('Failed to create blueprint, Response code is 500', 'ERROR')].join("\n")

        errors = bare_helper.send(:error_lines, out)

        assert_equal ['Failed to create blueprint, Response code is 500'], errors
    end

end

class ConstructorTest < Minitest::Test

    def test_bare_host_gets_https
        assert_equal 'https://10.0.0.5', quiet_helper(:server => '10.0.0.5').server
    end

    def test_trailing_slash_stripped
        assert_equal 'https://shift.local', quiet_helper(:server => 'https://shift.local/').server
    end

    def test_port_rejected
        err = assert_raises(ArgumentError) { quiet_helper(:server => 'https://10.0.0.5:3700') }
        assert_includes err.message, 'must not include a port'
    end

    def test_missing_credentials_rejected
        assert_raises(ArgumentError) { quiet_helper(:username => '') }
        assert_raises(ArgumentError) { quiet_helper(:password => '') }
    end

end

class VmDetailTest < Minitest::Test

    def test_minimal_conversion_fields
        vm = NetAppShift::Helper.vm_detail(:name => 'web01',
                                           :resource_group_name => 'rg1',
                                           :boot_order => 2)

        assert_equal({ 'name' => 'web01', 'boot_order' => 2,
                       'resource_group_name' => 'rg1' }, vm)
    end

    def test_requires_name
        assert_raises(ArgumentError) { NetAppShift::Helper.vm_detail({}) }
    end

end

class ConvertedDisksTest < Minitest::Test

    def test_single_disk
        Dir.mktmpdir do |mount|
            File.write(File.join(mount, 'web01.qcow2'), 'x')

            assert_equal [File.join(mount, 'web01.qcow2')],
                         bare_helper.converted_disks('web01', mount, 1)
        end
    end

    def test_multi_disk_ordering
        Dir.mktmpdir do |mount|
            # Shift naming observed on hardware: base, _1, _2
            ['multi.qcow2', 'multi_1.qcow2', 'multi_2.qcow2'].each do |f|
                File.write(File.join(mount, f), 'x')
            end

            disks = bare_helper.converted_disks('multi', mount, 3)

            assert_equal ['multi.qcow2', 'multi_1.qcow2', 'multi_2.qcow2'],
                         disks.map {|d| File.basename(d) }
        end
    end

    def test_missing_disks_named_in_error
        Dir.mktmpdir do |mount|
            File.write(File.join(mount, 'web01.qcow2'), 'x')

            err = assert_raises(NetAppShift::Error) do
                bare_helper.converted_disks('web01', mount, 2)
            end

            assert_includes err.message, 'web01_1.qcow2'
            refute_includes err.message, "web01.qcow2,"
        end
    end

    def test_does_not_glob_similar_names
        Dir.mktmpdir do |mount|
            # A neighboring VM whose name shares the prefix must not satisfy
            # the check for the missing disk.
            File.write(File.join(mount, 'web01-old.qcow2'), 'x')

            assert_raises(NetAppShift::Error) do
                bare_helper.converted_disks('web01', mount, 1)
            end
        end
    end

    def test_rejects_non_positive_count
        assert_raises(ArgumentError) { bare_helper.converted_disks('web01', '/mnt', 0) }
    end

end

class WaitForCompletionTest < Minitest::Test

    def make_result(data)
        NetAppShift::Result.new(:check_migration_status, :data => data, :duration => 0.1)
    end

    # Helper whose check_migration_status replays canned results
    def waiting_helper(results)
        helper = quiet_helper
        queue  = results.dup
        helper.define_singleton_method(:check_migration_status) do |_bp, _exec|
            queue.shift || raise('check_migration_status called too many times')
        end
        helper.define_singleton_method(:sleep_between_polls) { nil }
        helper
    end

    def ok_result
        make_result(:ok => true, :status => 'convert_complete', :complete => true,
                    :running => false, :jobs_ok => true)
    end

    def running_result
        make_result(:ok => false, :status => 'False', :complete => false, :running => true)
    end

    def error_result
        make_result(:ok => false, :status => 'convert_error', :complete => false,
                    :running => false)
    end

    def test_returns_terminal_ok_result
        helper = waiting_helper([ok_result])

        result = helper.wait_for_completion('bp', 'exec-1')

        assert result.ok?
        assert_equal 'convert_complete', result[:status]
    end

    def test_loops_past_python_polling_ceiling
        helper = waiting_helper([running_result, running_result, ok_result])

        helper.stub(:sleep, nil) do
            assert helper.wait_for_completion('bp', 'exec-1').ok?
        end
    end

    def test_raises_on_error_status
        helper = waiting_helper([error_result])

        assert_raises(NetAppShift::OperationError) do
            helper.wait_for_completion('bp', 'exec-1')
        end
    end

    def test_raises_on_complete_with_failed_jobs
        helper = waiting_helper([make_result(:ok => false, :status => 'convert_complete',
                                             :complete => true, :running => false,
                                             :jobs_ok => false)])

        assert_raises(NetAppShift::OperationError) do
            helper.wait_for_completion('bp', 'exec-1')
        end
    end

    def test_overall_timeout
        helper = waiting_helper([running_result, running_result, running_result])

        helper.stub(:sleep, nil) do
            err = assert_raises(NetAppShift::OperationError) do
                # An already-expired deadline: the first still-running result
                # must trip the overall timeout rather than polling again.
                helper.wait_for_completion('bp', 'exec-1', :timeout => 1e-9)
            end

            assert_includes err.message, 'Timed out'
        end
    end

    def test_nil_timeout_keeps_waiting
        helper = waiting_helper([running_result] * 5 + [ok_result])

        helper.stub(:sleep, nil) do
            assert helper.wait_for_completion('bp', 'exec-1', :timeout => nil).ok?
        end
    end

end

class BlueprintVmNamesTest < Minitest::Test

    BLUEPRINTS = {
        'list' => [
            { '_id' => 'bp-1', 'name' => 'bp_web',
              'protectionGroups' => [{ '_id' => 'rg-1' }] },
            { '_id' => 'bp-2', 'name' => 'bp_all',
              'protectionGroups' => [{ '_id' => 'rg-1' }, { '_id' => 'rg-2' }] }
        ]
    }.freeze

    GROUPS = {
        'list' => [
            { '_id' => 'rg-1', 'name' => 'group1',
              'vms' => [{ '_id' => 'vm-1', 'name' => 'web01' },
                        { '_id' => 'vm-2', 'name' => 'web02' }] },
            { '_id' => 'rg-2', 'name' => 'group2',
              'vms' => [{ '_id' => 'vm-3', 'name' => 'db01' }] },
            { '_id' => 'rg-9', 'name' => 'unrelated',
              'vms' => [{ '_id' => 'vm-9', 'name' => 'other' }] }
        ]
    }.freeze

    # Helper whose api_request replays canned appliance responses
    def rest_helper
        helper = quiet_helper
        calls  = []
        helper.define_singleton_method(:api_request) do |_method, _port, path, **_kw|
            calls << path
            case path
            when '/api/tenant/session'     then { 'session' => { '_id' => 'sid-1' } }
            when '/api/tenant/session/end' then {}
            when '/api/setup/drplan'          then BLUEPRINTS
            when '/api/setup/protectionGroup' then GROUPS
            else raise "unexpected path #{path}"
            end
        end
        [helper, calls]
    end

    def test_single_group
        helper, = rest_helper

        assert_equal %w[web01 web02], helper.blueprint_vm_names('bp_web')
    end

    def test_multiple_groups_in_order
        helper, = rest_helper

        assert_equal %w[web01 web02 db01], helper.blueprint_vm_names('bp_all')
    end

    def test_unknown_blueprint_lists_available
        helper, = rest_helper

        err = assert_raises(NetAppShift::OperationError) do
            helper.blueprint_vm_names('nope')
        end

        assert_includes err.message, 'bp_web'
        assert_includes err.message, 'bp_all'
    end

    def test_session_always_ended
        helper, calls = rest_helper

        helper.blueprint_vm_names('bp_web')
        assert_includes calls, '/api/tenant/session/end'

        calls.clear
        assert_raises(NetAppShift::OperationError) { helper.blueprint_vm_names('nope') }
        assert_includes calls, '/api/tenant/session/end'
    end

end

class ScriptPlumbingTest < Minitest::Test

    # Build a fake script dir + interpreter that echoes the payload it was
    # given and replays a realistic success log to stderr (where Python
    # logging writes).
    def with_stub_env
        Dir.mktmpdir do |dir|
            script_dir = File.join(dir, 'Python')
            FileUtils.mkdir_p(script_dir)

            NetAppShift::Helper::OPERATIONS.each_value do |name|
                File.write(File.join(script_dir, "#{name}.py"), "# stub\n")
                File.write(File.join(script_dir, "#{name}.json"),
                           %({"executions": [{"execution_name": ""}]}\n))
                File.chmod(0o644, File.join(script_dir, "#{name}.json"))
            end

            stub = File.join(dir, 'fakepython')
            File.write(stub, <<~SH)
              #!/bin/bash
              if [ "$1" = "-c" ]; then exit 0; fi
              base="${1%.py}"
              cp "$base.json" "#{dir}/seen-$base.json"
              case "$base" in
                trigger_migration)
                  echo "#{log_line('Migration triggered for blueprint bp with execution id: ex-42')}" >&2 ;;
                check_migration_status)
                  echo "#{log_line('Status of Blueprint is convert_complete for blueprint bp-abc')}" >&2
                  echo "#{log_line('Job steps successfully completed for execution id ex-42')}" >&2 ;;
              esac
              exit 0
            SH
            FileUtils.chmod(0o755, stub)

            helper = quiet_helper(:script_dir => script_dir, :python => stub)

            yield helper, script_dir, dir
        end
    end

    def test_trigger_runs_and_parses
        with_stub_env do |helper, _script_dir, dir|
            result = helper.trigger_migration('bp')

            assert result.ok?
            assert_equal 'ex-42', result[:execution_id]
            assert_equal 0, result.exit_code

            seen = JSON.parse(File.read(File.join(dir, 'seen-trigger_migration.json')))
            exec = seen['executions'].first

            assert_equal 'admin', exec['shift_username']
            assert_equal 's3cr3t', exec['shift_password']
            assert_equal 'https://shift.local', exec['shift_server_ip']
            assert_equal 'bp', exec['blueprint_name']
            assert_equal 'clone_based_conversion', exec['migration_mode']
        end
    end

    def test_payload_file_restored_with_mode
        with_stub_env do |helper, script_dir, _dir|
            original = File.join(script_dir, 'trigger_migration.json')

            helper.trigger_migration('bp')

            assert_equal({ 'execution_name' => '' },
                         JSON.parse(File.read(original))['executions'].first)
            assert_equal '644', format('%o', File.stat(original).mode & 0o777)
        end
    end

    def test_check_migration_status_passes_execution_id
        with_stub_env do |helper, _script_dir, dir|
            result = helper.check_migration_status('bp', 'ex-42')

            assert result.ok?

            seen = JSON.parse(File.read(File.join(dir, 'seen-check_migration_status.json')))

            assert_equal 'ex-42', seen['executions'].first['execution_id']
        end
    end

    def test_check_bang_raises_with_last_error
        with_stub_env do |helper, _script_dir, _dir|
            # get_site stub logs nothing -> no success message
            err = assert_raises(NetAppShift::OperationError) do
                helper.check!(helper.get_site)
            end

            assert_includes err.message, 'get_site'
        end
    end

    def test_missing_script_dir_raises_dependency_error
        helper = quiet_helper(:script_dir => '/nonexistent/shift')

        err = assert_raises(NetAppShift::DependencyError) { helper.get_site }
        assert_includes err.message, 'submodule'
    end

    def test_dry_run_skips_python_and_redacts
        helper = quiet_helper(:script_dir => '/nonexistent', :dry_run => true)

        assert helper.get_site.ok?
        assert helper.get_site[:dry_run]

        redacted = helper.send(:redact, helper.send(:base_execution))

        assert_equal '[redacted]', redacted['shift_password']
        assert_equal 'admin', redacted['shift_username']
    end

end
