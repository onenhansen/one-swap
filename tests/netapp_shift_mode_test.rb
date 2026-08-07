# Unit-style checks for the NetApp Shift conversion mode in oneswap_helper.rb.
# Run with: ruby tests/netapp_shift_mode_test.rb

require 'fileutils'
require 'logger'
require 'minitest/autorun'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper; end
end

module Kernel
    alias oneswap_test_original_require require

    def require(path)
        return true if ['one_helper', 'opennebula'].include?(path)

        oneswap_test_original_require(path)
    end
end

require_relative '../oneswap_helper'

# Minimal stand-in for Process::Status
FakeStatus = Struct.new(:ok) do
    def success?
        ok
    end
end

class NetAppShiftModeTest < Minitest::Test

    def helper(options = {})
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, options)
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    # Helper wired for run_shift_conversion: n vCenter disks, quiet preflight,
    # captured commands and imports. Returns [helper, commands, imported].
    def conversion_helper(mount, work_dir, disk_count, options = {})
        h = helper({ :name        => 'web01',
                     :shift       => 'https://shift.local',
                     :shift_mount => mount,
                     :work_dir    => work_dir }.merge(options))

        commands = []
        imported = nil

        h.define_singleton_method(:local_path_image_allocation_preflight!) { nil }
        h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| nil }
        h.define_singleton_method(:vc_virtual_disks) { Array.new(disk_count, :disk) }
        h.define_singleton_method(:new_netapp_shift) {|_opts| NetAppShift::Helper.allocate }
        h.define_singleton_method(:run_cmd_report) do |cmd, _out = false, **_kw|
            commands << cmd
            ['', FakeStatus.new(true)]
        end
        h.define_singleton_method(:create_one_images) do |disks|
            imported = disks
            [{ :id => 1, :os => false }]
        end
        h.instance_variable_set(:@props,
                                'config' => { :hardware => { :memoryMB => 2048 } })

        [h, commands, proc { imported }]
    end

    def test_missing_disk_raises_before_any_command
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                h, commands, = conversion_helper(mount, work_dir, 1)

                err = assert_raises(NetAppShift::Error) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'web01.qcow2'
                assert_empty commands
            end
        end
    end

    def test_single_disk_uses_i_disk_in_place
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                disk = File.join(mount, 'web01.qcow2')
                File.write(disk, 'x')

                h, commands, imported = conversion_helper(mount, work_dir, 1)
                h.send(:run_shift_conversion)

                assert_equal 1, commands.size
                assert_includes commands.first, 'virt-v2v-in-place'
                assert_includes commands.first, "-i disk #{disk}"
                assert_includes commands.first, '--machine-readable'

                # imported straight from the mount, no copy anywhere
                assert_equal [disk], imported.call
                assert File.exist?(disk)
                assert_empty Dir.children(work_dir)
            end
        end
    end

    def test_multi_disk_uses_libvirtxml_with_ordered_disks
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                disks = ['web01.qcow2', 'web01_1.qcow2', 'web01_2.qcow2']
                        .map {|f| File.join(mount, f) }
                disks.each {|d| File.write(d, 'x') }

                h, commands, imported = conversion_helper(mount, work_dir, 3)
                h.send(:run_shift_conversion)

                assert_includes commands.first, '-i libvirtxml'

                xml_path = File.join(work_dir, 'web01-shift-domain.xml')
                assert File.exist?(xml_path)

                xml = File.read(xml_path)
                # all three disks referenced, in device order
                positions = disks.map {|d| xml.index("file='#{d}'") }
                assert positions.all?, "missing disk in domain XML: #{xml}"
                assert_equal positions.sort, positions

                assert_equal disks, imported.call
            end
        end
    end

    def test_failed_morph_raises_and_skips_import
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, _commands, imported = conversion_helper(mount, work_dir, 1)
                h.define_singleton_method(:run_cmd_report) do |_cmd, _out = false, **_kw|
                    ['', FakeStatus.new(false)]
                end

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'virt-v2v-in-place failed'
                assert_nil imported.call
            end
        end
    end

    def test_libguestfs_path_exported_to_command
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, commands, = conversion_helper(mount, work_dir, 1,
                                                 :libguestfs_path => '/var/lib/one/appliance')
                h.send(:run_shift_conversion)

                assert_match(%r{^LIBGUESTFS_PATH=/var/lib/one/appliance virt-v2v-in-place},
                             commands.first)
            end
        end
    end

    def test_zero_disks_raises
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                h, = conversion_helper(mount, work_dir, 0)

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'no virtual disks'
            end
        end
    end

end

# Fake NetAppShift::Helper for orchestration tests
class FakeShift

    attr_reader :calls

    def initialize(responses = {})
        @responses = responses
        @calls     = []
    end

    def run_compliance_check(bp)
        @calls << [:compliance, bp]
        @responses.fetch(:compliance)
    end

    def trigger_migration(bp)
        @calls << [:trigger, bp]
        @responses.fetch(:trigger)
    end

    def wait_for_completion(bp, exec_id, timeout: nil)
        @calls << [:wait, bp, exec_id, timeout]
        @responses.fetch(:wait)
    end

    def blueprint_vm_names(bp)
        @calls << [:vm_names, bp]
        @responses.fetch(:vm_names)
    end

    def check!(result)
        raise NetAppShift::OperationError, "failed: #{result.operation}" unless result.ok?

        result
    end

end

class ShiftExecuteBlueprintTest < Minitest::Test

    OPTIONS = {
        :shift            => 'https://shift.local',
        :shift_user       => 'admin',
        :shift_pass       => 'p',
        :shift_blueprint  => 'bp1',
        :shift_wait_timeout => 3600
    }.freeze

    def result(op, data)
        NetAppShift::Result.new(op, :data => data, :duration => 0.1)
    end

    def orchestration_helper(fake)
        h = OneSwapHelper.allocate
        h.instance_variable_set(:@logger, Logger.new(File::NULL))
        h.instance_variable_set(:@verbose, true) # short-circuit apply_verbosity
        h.define_singleton_method(:check_one_connectivity) { nil }
        h.define_singleton_method(:local_path_image_allocation_preflight!) { nil }
        h.define_singleton_method(:new_netapp_shift) {|_opts| fake }
        h
    end

    def test_happy_path_passes_blueprint_execution_id_and_timeout
        fake = FakeShift.new(
            :compliance => result(:run_compliance_check, :ok => true),
            :trigger    => result(:trigger_migration, :ok => true, :execution_id => 'ex-9'),
            :wait       => result(:check_migration_status,
                                  :ok => true, :status => 'convert_complete')
        )
        h = orchestration_helper(fake)

        capture_io { h.shift_execute_blueprint(OPTIONS.dup) }

        assert_includes fake.calls, [:compliance, 'bp1']
        assert_includes fake.calls, [:trigger, 'bp1']
        assert_includes fake.calls, [:wait, 'bp1', 'ex-9', 3600]
    end

    def test_missing_execution_id_raises
        fake = FakeShift.new(
            :compliance => result(:run_compliance_check, :ok => true),
            :trigger    => result(:trigger_migration, :ok => true) # no execution_id
        )
        h = orchestration_helper(fake)

        err = assert_raises(RuntimeError) do
            capture_io { h.shift_execute_blueprint(OPTIONS.dup) }
        end

        assert_includes err.message, 'no execution id'
    end

    def test_operation_error_becomes_plain_runtime_error
        fake = FakeShift.new(:compliance => result(:run_compliance_check, :ok => false))
        h = orchestration_helper(fake)

        err = assert_raises(RuntimeError) do
            capture_io { h.shift_execute_blueprint(OPTIONS.dup) }
        end

        refute_kind_of NetAppShift::OperationError, err
        assert_includes err.message, 'run_compliance_check'
    end

    def test_blueprint_vm_names_delegates
        fake = FakeShift.new(:vm_names => %w[web01 db01])
        h = orchestration_helper(fake)

        assert_equal %w[web01 db01], h.shift_blueprint_vm_names(OPTIONS.dup)
    end

end
