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

# Fake NetAppShift::Helper for the orchestration tests. Mirrors the real
# client's contract: reads return data, actions raise on failure.
class FakeShift

    attr_reader :calls

    def initialize(responses = {})
        @responses = responses
        @calls     = []
    end

    def verbs
        @calls.map(&:first)
    end

    def blueprint_execution_state(blueprint)
        @calls << [:state, blueprint]
        replay(:state, nil)
    end

    def blueprint_vm_names(blueprint)
        @calls << [:vm_names, blueprint]
        replay(:vm_names)
    end

    def run_compliance_check(blueprint)
        @calls << [:compliance, blueprint]
        replay(:compliance, {})
    end

    def trigger_conversion(blueprint)
        @calls << [:trigger, blueprint]
        replay(:trigger)
    end

    def wait_for_completion(blueprint, execution_id, timeout: nil)
        @calls << [:wait, blueprint, execution_id, timeout]
        replay(:wait, { :status => 'complete' })
    end

    private

    # A stored exception is raised; anything else is returned.
    def replay(key, default = :__required__)
        value = @responses.fetch(key) do
            raise "test: FakeShift has no :#{key} response" if default == :__required__

            default
        end

        raise value if value.is_a?(Class) && value <= StandardError
        raise value if value.is_a?(StandardError)

        value
    end

end

class ShiftExecuteBlueprintTest < Minitest::Test

    OPTIONS = {
        :shift               => 'https://shift.local',
        :shift_user          => 'admin',
        :shift_pass          => 'p',
        :shift_blueprint     => 'bp1',
        :shift_mount         => '/mnt/shift',
        :shift_wait_timeout  => 3600
    }.freeze

    def orchestration_helper(fake)
        h = OneSwapHelper.allocate
        h.instance_variable_set(:@logger, Logger.new(File::NULL))
        h.instance_variable_set(:@verbose, true) # short-circuits apply_verbosity
        h.define_singleton_method(:check_one_connectivity) { nil }
        h.define_singleton_method(:local_path_image_allocation_preflight!) { nil }
        h.define_singleton_method(:new_netapp_shift) {|_opts| fake }
        h
    end

    def run_it(fake)
        capture_io { orchestration_helper(fake).shift_execute_blueprint(OPTIONS.dup) }
    end

    def test_happy_path_passes_blueprint_execution_id_and_timeout
        fake = FakeShift.new(:state => nil, :trigger => 'ex-9')

        run_it(fake)

        assert_includes fake.calls, [:compliance, 'bp1']
        assert_includes fake.calls, [:trigger, 'bp1']
        assert_includes fake.calls, [:wait, 'bp1', 'ex-9', 3600]
    end

    # The reported bug: a blueprint that already converted must not be
    # triggered again, it must fall through to import.
    def test_already_converted_state_skips_compliance_and_trigger
        fake = FakeShift.new(:state => { :status => 'convert_complete', :complete => true,
                                         :running => false, :failed => false,
                                         :execution_id => 'ex-1' })

        out, = run_it(fake)

        assert_equal [[:state, 'bp1']], fake.calls
        assert_includes out, 'already been converted'
    end

    # And when the status endpoint does not report it, Shift's own rejection
    # of the second execution must be treated the same way.
    def test_already_executed_on_trigger_is_not_an_error
        fake = FakeShift.new(:state => nil, :trigger => NetAppShift::AlreadyExecuted)

        out, = run_it(fake)

        assert_includes out, 'already been converted'
        refute_includes fake.verbs, :wait
    end

    def test_running_blueprint_attaches_to_existing_execution
        fake = FakeShift.new(:state => { :status => 'convert_inprogress', :complete => false,
                                         :running => true, :failed => false,
                                         :execution_id => 'ex-7' })

        run_it(fake)

        assert_includes fake.calls, [:wait, 'bp1', 'ex-7', 3600]
        refute_includes fake.verbs, :trigger
        refute_includes fake.verbs, :compliance
    end

    def test_failed_blueprint_raises_without_triggering
        fake = FakeShift.new(:state => { :status => 'convert_error', :complete => false,
                                         :running => false, :failed => true,
                                         :execution_id => 'ex-3' })

        err = assert_raises(RuntimeError) { run_it(fake) }

        assert_includes err.message, 'last execution failed'
        refute_includes fake.verbs, :trigger
    end

    def test_compliance_failure_becomes_a_plain_error
        fake = FakeShift.new(
            :state      => nil,
            :compliance => NetAppShift::OperationError.new('compliance check failed: nope')
        )

        err = assert_raises(RuntimeError) { run_it(fake) }

        refute_kind_of NetAppShift::Error, err
        assert_includes err.message, 'compliance check failed'
        refute_includes fake.verbs, :trigger
    end

    def test_trigger_failure_propagates
        fake = FakeShift.new(
            :state   => nil,
            :trigger => NetAppShift::OperationError.new('returned no execution id')
        )

        err = assert_raises(RuntimeError) { run_it(fake) }

        assert_includes err.message, 'no execution id'
        refute_includes fake.verbs, :wait
    end

    def test_blueprint_vm_names_delegates
        fake = FakeShift.new(:vm_names => %w[web01 db01])
        h = orchestration_helper(fake)

        assert_equal %w[web01 db01], h.shift_blueprint_vm_names(OPTIONS.dup)
    end

end
