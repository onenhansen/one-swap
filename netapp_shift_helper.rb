# -------------------------------------------------------------------------- #
# Copyright 2002-2026, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'digest'
require 'fileutils'
require 'json'
require 'logger'
require 'net/http'
require 'open3'
require 'openssl'
require 'tmpdir'
require 'uri'

# NetApp Shift integration for OneSwap.
#
# This is a thin wrapper around the vendored NetApp "shift-api-automation"
# Python scripts (scripts/shift-api-automation/Python, a git submodule).
#
# The upstream scripts are not a library: each one reads a *fixed* JSON file
# next to itself (the path comes from Config.yml via conftest.py), talks to the
# Shift appliance, and reports what happened by *logging* to stderr. There is
# no structured output and no meaningful exit code -- the top-level scripts
# swallow exceptions and still exit 0.
#
# So the wrapper does three things for each operation:
#
#   1. Build the "executions" JSON payload and write it to the path the script
#      expects, restoring the original file afterwards (the payload holds
#      plaintext credentials, so it is chmod 0600 while it exists).
#   2. Run the script with CWD set to the Python directory (its imports and its
#      logs/ directory are both relative to it).
#   3. Scrape the captured output for the identifiers and statuses the script
#      logged, and hand them back as a NetAppShift::Result.
#
# The Shift workflow OneSwap drives: the operator pre-creates the source site,
# destination site, resource group(s) and blueprint in the Shift UI. OneSwap
# then runs the compliance check, triggers the blueprint execution in
# "clone_based_conversion" mode (which converts every VM in the blueprint's
# resource groups in parallel) and waits for it to finish. The converted disks
# appear on the source NFS datastore next to each VM's folder:
#
#   <mount>/<vm-name>.qcow2         first disk
#   <mount>/<vm-name>_1.qcow2       second disk
#   <mount>/<vm-name>_2.qcow2       third disk, ...
#
#   shift = NetAppShift::Helper.new(
#       :server   => 'https://10.0.0.5',
#       :username => 'admin',
#       :password => 'secret',
#       :logger   => @logger
#   )
#
#   shift.blueprint_vm_names('bp1')                 # => ['web01', 'db01']
#   shift.check!(shift.run_compliance_check('bp1'))
#   trigger = shift.check!(shift.trigger_migration('bp1'))
#   shift.wait_for_completion('bp1', trigger[:execution_id])
#   shift.converted_disks('web01', '/mnt/shift', 2)
#   # => ['/mnt/shift/web01.qcow2', '/mnt/shift/web01_1.qcow2']
#
module NetAppShift

    class Error < StandardError; end

    # Raised when python3 or the vendored scripts/modules are not usable.
    class DependencyError < Error; end

    # Raised by check!/wait_for_completion/API reads when an operation did not
    # report success.
    class OperationError < Error

        attr_reader :result

        def initialize(message, result = nil)
            super(message)
            @result = result
        end

    end

    # Outcome of a single script invocation.
    class Result

        attr_reader :operation, :output, :errors, :data, :exit_code, :duration

        def initialize(operation, opts = {})
            @operation = operation
            @output    = opts[:output].to_s
            @errors    = opts[:errors] || []
            @data      = opts[:data] || {}
            @exit_code = opts[:exit_code]
            @duration  = opts[:duration]
            @timed_out = opts[:timed_out] ? true : false
        end

        def timed_out?
            @timed_out
        end

        # True when the script logged the messages that mean "this worked".
        # Exit codes are useless here: the upstream scripts catch everything
        # and still exit 0.
        def ok?
            !timed_out? && @data[:ok] == true
        end

        def [](key)
            @data[key.to_sym]
        end

        def to_h
            @data.merge(
                :operation => @operation,
                :ok        => ok?,
                :timed_out => timed_out?,
                :exit_code => @exit_code,
                :duration  => @duration,
                :errors    => @errors
            )
        end

        def to_s
            "#{@operation}: #{ok? ? 'ok' : 'failed'} (#{@duration}s)"
        end

    end

    # Wrapper around the vendored shift-api-automation Python scripts, plus a
    # minimal read-only REST client for the lookups the scripts cannot express
    # (they log Python repr, not JSON).
    class Helper

        # Vendored submodule, relative to this file.
        SCRIPT_DIR = File.join(__dir__, 'scripts', 'shift-api-automation', 'Python')

        # Shift workflow types. "clone_based_conversion" is the disk-only
        # workflow (POST .../convert/execution) OneSwap wants: it converts the
        # VMDKs on the ONTAP volume without building a VM on the target
        # hypervisor. "clone_based_migration" (POST .../migrate/execution)
        # additionally creates and configures the target VM.
        CONVERSION = 'clone_based_conversion'.freeze
        MIGRATION  = 'clone_based_migration'.freeze

        # Appliance service ports, matching the Python API modules: the tenant
        # session service, the setup service (sites/resource groups/plans) and
        # the recovery service (executions/job status).
        SESSION_PORT  = 3698
        SETUP_PORT    = 3700
        RECOVERY_PORT = 3704

        # operation => basename shared by the script and its JSON payload.
        # The payload path is fixed by Config.yml, so it cannot be overridden
        # per run; see #with_payload for how that is handled.
        OPERATIONS = {
            :get_site               => 'get_site',
            :create_blueprint       => 'create_blueprint',
            :run_compliance_check   => 'run_compliance_check',
            :trigger_migration      => 'trigger_migration',
            :check_migration_status => 'check_migration_status'
        }.freeze

        # check_migration_status polls in-process: verify_blueprint_status
        # loops 40x with a 30s sleep (~20 min) before giving up. The wrapper
        # ceiling sits above that so it never kills a healthy run;
        # #wait_for_completion handles executions that outlast the script's
        # own polling window.
        DEFAULT_TIMEOUTS = {
            :get_site               => 120,
            :create_blueprint       => 600,
            :run_compliance_check   => 300,
            :trigger_migration      => 600,
            :check_migration_status => 2700
        }.freeze

        # trigger_migration.py imports utils.db_utils at module scope, which
        # imports pymongo, even though the flow never touches Mongo. It still
        # has to be installed.
        PYTHON_MODULES = ['requests', 'envyaml', 'pymongo'].freeze

        attr_reader :logger, :script_dir, :server

        # @param options [Hash]
        # @option options :server     [String] Shift appliance base URL, scheme
        #   and host only. Ports (3698/3700/3704) are appended per service.
        # @option options :username   [String] Shift login
        # @option options :password   [String] Shift password
        # @option options :script_dir [String] override the vendored Python dir
        # @option options :python     [String] interpreter, default "python3"
        # @option options :logger     [Logger]
        # @option options :timeouts   [Hash] per operation overrides, seconds
        # @option options :execution_name [String] label recorded in payloads
        # @option options :keep_payload [Boolean] leave the rendered JSON on
        #   disk after the run (debugging only -- it contains passwords)
        # @option options :dry_run    [Boolean] build and log payloads without
        #   invoking Python
        def initialize(options = {})
            @server   = normalize_server(options[:server])
            @username = options[:username].to_s
            @password = options[:password].to_s

            if @username.empty? || @password.empty?
                raise ArgumentError, 'Shift :username and :password are required'
            end

            @script_dir = File.expand_path(options[:script_dir] || SCRIPT_DIR)
            @python     = options[:python] || 'python3'
            @logger     = options[:logger] || self.class.stdout_logger
            @timeouts   = DEFAULT_TIMEOUTS.merge(options[:timeouts] || {})

            @execution_name = options[:execution_name] || 'oneswap'
            @keep_payload   = options[:keep_payload] ? true : false
            @dry_run        = options[:dry_run] ? true : false

            @checked = false
        end

        def self.stdout_logger
            logger = Logger.new(STDOUT)
            logger.level = Logger::INFO
            logger
        end

        # ------------------------------------------------------------------ #
        # Payload builders                                                    #
        # ------------------------------------------------------------------ #

        # Build one vm_details entry for #create_blueprint.
        #
        # In clone_based_conversion mode the upstream blueprint builder only
        # uses vm_details to resolve the resource group by name and the VM ids
        # inside it (the vmSettings block is dropped entirely), so only these
        # three keys matter. The VM must already exist in the named resource
        # group or the Python exits.
        #
        # @option options :name [String] VM name exactly as vCenter reports it
        # @option options :resource_group_name [String] pre-created resource
        #   group this VM belongs to
        # @option options :boot_order [Integer]
        def self.vm_detail(options = {})
            name = options[:name].to_s

            raise ArgumentError, 'vm_detail requires :name' if name.empty?

            {
                'name'                => name,
                'boot_order'          => options.fetch(:boot_order, 1),
                'resource_group_name' => options[:resource_group_name].to_s
            }
        end

        # ------------------------------------------------------------------ #
        # Script-backed operations                                            #
        # ------------------------------------------------------------------ #

        # GET the sites registered on the appliance. Cheap connectivity and
        # credentials preflight; the site list itself is only logged as Python
        # repr, so read names from Result#output or the Shift UI.
        def get_site
            run(:get_site)
        end

        # Create a blueprint (DR plan) tying pre-created resource groups to
        # the source and destination sites. Unused by the v1 OneSwap CLI
        # (operators create blueprints in the Shift UI) but kept for a future
        # mode where OneSwap creates them itself.
        #
        # blueprint.py reads ip_type and the windows/linux service account keys
        # with [], not .get(), so they have to be present even for a conversion
        # where they go unused. They default to empty strings here.
        def create_blueprint(options = {})
            require_options!(options, :blueprint_name, :source_site_name,
                             :destination_site_name, :vm_details)

            accounts = options[:service_accounts] || {}

            run(:create_blueprint,
                'blueprint_name'        => options[:blueprint_name].to_s,
                'source_site_name'      => options[:source_site_name].to_s,
                'destination_site_name' => options[:destination_site_name].to_s,
                'migration_mode'        => options.fetch(:migration_mode, CONVERSION),
                'vm_details'            => normalize_vm_details(options[:vm_details]),
                # Source resource name => target resource name. Only consumed
                # by clone_based_migration; ignored for a conversion.
                'mappings'              => stringify(options[:mappings] || {}),
                'ip_type'               => options.fetch(:ip_type, 'dhcp').to_s,
                'windows_loginId'       => accounts.dig(:windows, :login_id).to_s,
                'windows_password'      => accounts.dig(:windows, :password).to_s,
                'linux_loginId'         => accounts.dig(:linux, :login_id).to_s,
                'linux_password'        => accounts.dig(:linux, :password).to_s)
        end

        # Run the compliance check for a blueprint and wait for the verdict.
        # The script sleeps 20s before it starts, to let the blueprint settle.
        def run_compliance_check(blueprint_name, migration_mode = CONVERSION)
            run(:run_compliance_check,
                'blueprint_name' => blueprint_name.to_s,
                'migration_mode' => migration_mode.to_s)
        end

        # Execute the blueprint. With CONVERSION this POSTs to
        # .../convert/execution (disks only); with MIGRATION it POSTs to
        # .../migrate/execution. Returns as soon as Shift accepts the job --
        # the execution id it yields is what #check_migration_status needs.
        def trigger_migration(blueprint_name, migration_mode = CONVERSION)
            run(:trigger_migration,
                'blueprint_name' => blueprint_name.to_s,
                'migration_mode' => migration_mode.to_s)
        end

        # Check/wait on the execution: the script polls the blueprint status
        # (up to ~20 min) and then validates every job step. A result whose
        # :status is nil or "False" means the script gave up waiting while the
        # execution was still running -- see #wait_for_completion.
        def check_migration_status(blueprint_name, execution_id)
            run(:check_migration_status,
                'blueprint_name' => blueprint_name.to_s,
                'execution_id'   => execution_id.to_s)
        end

        # Block until the blueprint execution reaches a terminal state, by
        # re-invoking check_migration_status as often as needed (each run
        # waits up to ~20 min inside the Python, so this survives conversions
        # of any length).
        #
        # @param timeout [Integer, nil] overall ceiling in seconds; nil or 0
        #   waits forever (the caller decides how to surface Ctrl+C)
        # @return [Result] the terminal check_migration_status result
        def wait_for_completion(blueprint_name, execution_id, timeout: nil)
            deadline = Time.now + timeout.to_f if timeout && timeout.to_f > 0
            t0       = Time.now

            loop do
                result = check_migration_status(blueprint_name, execution_id)

                return result if result.ok?

                status = result[:status]

                if result[:complete] || status.to_s.include?('error')
                    # Terminal but not ok: completed-with-failed-steps or an
                    # error status.
                    check!(result)
                end

                waited = (Time.now - t0).round
                @logger.info("NetApp Shift: blueprint '#{blueprint_name}' still " \
                             "running after #{waited}s, polling again")

                if deadline && Time.now >= deadline
                    raise OperationError.new(
                        "Timed out after #{waited}s waiting for blueprint " \
                        "'#{blueprint_name}' execution #{execution_id}",
                        result
                    )
                end

                # The script itself polls for minutes; this only paces the
                # rare quick-return cases (e.g. transient API errors).
                sleep 10
            end
        end

        # ------------------------------------------------------------------ #
        # Read-only REST lookups                                              #
        #                                                                     #
        # The Python scripts log these objects as Python repr, which is not   #
        # machine readable, so the reads go straight to the appliance API     #
        # (same endpoints, ports and headers the Python modules use). If the  #
        # submodule fork ever adds JSON-printing scripts, replace these.      #
        # ------------------------------------------------------------------ #

        # VM names covered by a blueprint, in resource-group order. This is
        # what a blueprint execution will convert.
        #
        # @return [Array<String>]
        def blueprint_vm_names(blueprint_name)
            api_session do |sid|
                blueprint = api_find_blueprint(sid, blueprint_name)

                rg_ids = Array(blueprint['protectionGroups']).map {|rg| rg['_id'] }.compact
                groups = api_list(sid, '/api/setup/protectionGroup')
                         .select {|rg| rg_ids.include?(rg['_id']) }

                names = groups.flat_map {|rg| Array(rg['vms']).map {|vm| vm['name'] } }
                              .compact

                if names.empty?
                    raise OperationError,
                          "Blueprint '#{blueprint_name}' has no VMs in its " \
                          'resource group(s)'
                end

                names
            end
        end

        # Current execution state of a blueprint, or nil if it has never run.
        #
        # This is what makes repeat invocations work: a blueprint that has
        # already executed cannot be executed again until its prior executions
        # are deleted (NetApp ships PowerShell/removeBpJobs.ps1 for that), and
        # one execution converts every VM in the resource group anyway. So the
        # caller checks here first and imports the existing disks instead of
        # triggering a second time.
        #
        # GET :3704/api/recovery/drplan/status returns a list of
        #   { 'drPlan' => {'_id', 'recoveryStatus'}, 'lastExecution' => {'_id', 'status'} }
        # recoveryStatus is the same string verify_blueprint_status keys off:
        # it contains "complete" or "error" once terminal.
        #
        # Note this is only an optimisation: it saves a pointless compliance
        # check and trigger. The authoritative signal that a blueprint cannot
        # run again is the ERSCSTEX009 error the trigger itself returns, which
        # #parse_trigger_migration reports as :already_executed.
        #
        # @return [Hash, nil] :status, :execution_id, :complete, :failed, :running
        def blueprint_execution_state(blueprint_name)
            api_session do |sid|
                id       = api_find_blueprint(sid, blueprint_name)['_id']
                response = api_get(sid, RECOVERY_PORT, '/api/recovery/drplan/status')

                @logger.debug("NetApp Shift: drplan/status -> #{response.inspect}")

                # Bare array in the appliances seen so far, but tolerate the
                # setup service's {'list' => [...]} envelope too.
                entries = response.is_a?(Hash) ? Array(response['list']) : Array(response)

                entry = entries.find do |e|
                    e.is_a?(Hash) && e.dig('drPlan', '_id') == id
                end

                if entry.nil?
                    @logger.debug("NetApp Shift: blueprint #{id} not present in drplan/status")
                    next nil
                end

                status = entry.dig('drPlan', 'recoveryStatus').to_s

                next nil if status.empty?

                {
                    :status       => status,
                    :execution_id => entry.dig('lastExecution', '_id'),
                    :complete     => status.include?('complete'),
                    :failed       => status.include?('error'),
                    :running      => !status.match?(/complete|error/)
                }
            end
        end

        # ------------------------------------------------------------------ #
        # Locating the converted disks                                        #
        # ------------------------------------------------------------------ #

        # Paths of the converted disks for a VM on the locally mounted source
        # NFS datastore, in disk order.
        #
        # Observed Shift naming (verified on hardware, single and multi-disk):
        # the first disk is "<vm-name>.qcow2" and each additional disk is
        # "<vm-name>_<n>.qcow2", all directly in the datastore root next to
        # the VM's folder. Disk order is assumed to follow the source device
        # order (base name = first disk).
        #
        # @param vm_name [String]
        # @param mount   [String]  local mount point of the datastore
        # @param count   [Integer] number of disks the VM has (from vCenter)
        # @return [Array<String>] existing paths, first disk first
        # @raise [Error] naming every expected file that is missing
        def converted_disks(vm_name, mount, count)
            raise ArgumentError, 'converted_disks requires a positive disk count' if
                count.to_i < 1

            expected = [File.join(mount.to_s, "#{vm_name}.qcow2")]
            (1...count.to_i).each do |i|
                expected << File.join(mount.to_s, "#{vm_name}_#{i}.qcow2")
            end

            missing = expected.reject {|path| File.file?(path) }

            unless missing.empty?
                raise Error,
                      "Converted disk(s) not found for '#{vm_name}': " \
                      "#{missing.join(', ')}. Verify the mount point and that " \
                      'the blueprint execution completed.'
            end

            expected
        end

        # ------------------------------------------------------------------ #
        # Plumbing                                                            #
        # ------------------------------------------------------------------ #

        # Run one operation with a single execution entry.
        #
        # @return [NetAppShift::Result]
        def run(operation, execution = {})
            run_many(operation, [execution])
        end

        # Run one operation over several execution entries. Upstream loops the
        # "executions" array, so batching works, but the scrapers report on the
        # combined output -- prefer one entry per call when the ids matter.
        def run_many(operation, executions)
            op   = operation.to_sym
            name = OPERATIONS[op]

            raise ArgumentError, "Unknown Shift operation: #{operation}" if name.nil?

            payload = {
                'executions' => executions.map {|e| base_execution.merge(stringify(e)) }
            }

            if @dry_run
                @logger.info("NetApp Shift: [dry-run] #{name}.json\n" \
                             "#{JSON.pretty_generate(redact(payload))}")

                return Result.new(op, :data => { :ok => true, :dry_run => true })
            end

            ensure_dependencies!

            @logger.debug("NetApp Shift: #{name}.json\n#{JSON.pretty_generate(redact(payload))}")

            output, status, timed_out, duration = with_payload(name, payload) do
                execute("#{name}.py", @timeouts.fetch(op, 600))
            end

            result = Result.new(op,
                                :output    => output,
                                :errors    => error_lines(output),
                                :data      => parse(op, output),
                                :exit_code => status && status.exitstatus,
                                :timed_out => timed_out,
                                :duration  => duration)

            log_result(result)

            result
        end

        # Raise unless the result reports success.
        def check!(result)
            return result if result.ok?

            # The scripts log root cause first and a generic trailer last
            # ("Migration trigger failed for migration index 1"), so prefer
            # the line carrying the HTTP status and response body.
            reason = if result.timed_out?
                         "timed out after #{result.duration}s"
                     elsif result.errors.any?
                         result.errors.find {|e| e.include?('Response code') } ||
                             result.errors.first
                     else
                         'the script logged no success message'
                     end

            raise OperationError.new("NetApp Shift #{result.operation} failed: #{reason}", result)
        end

        # Verify python3, the vendored scripts and their imports are usable.
        # Memoized: it costs one interpreter start up per helper.
        def ensure_dependencies!
            return true if @checked

            unless File.directory?(@script_dir)
                raise DependencyError,
                      "Shift scripts not found at #{@script_dir}. The " \
                      'shift-api-automation submodule is probably not checked ' \
                      'out (git submodule update --init).'
            end

            missing = OPERATIONS.values.reject do |name|
                File.file?(File.join(@script_dir, "#{name}.py"))
            end

            unless missing.empty?
                raise DependencyError,
                      "Missing Shift scripts in #{@script_dir}: " \
                      "#{missing.map {|m| "#{m}.py" }.join(', ')}"
            end

            imports = PYTHON_MODULES.map {|mod| "import #{mod}" }.join('; ')

            _stdout, stderr, status =
                Open3.capture3(@python, '-c', imports, :chdir => @script_dir)

            unless status.success?
                raise DependencyError,
                      "#{@python} cannot import the Shift dependencies " \
                      "(#{PYTHON_MODULES.join(', ')}): #{stderr.strip}"
            end

            @checked = true
        end

        private

        # Shift's URI is built as "<server>:<port>/api/...", so the value has
        # to carry a scheme and nothing else.
        def normalize_server(server)
            value = server.to_s.strip.sub(%r{/+\z}, '')

            raise ArgumentError, 'Shift :server is required' if value.empty?

            value = "https://#{value}" unless value.match?(%r{\A\w+://})

            if value.match?(%r{\A\w+://[^/]+:\d+\z})
                raise ArgumentError,
                      "Shift :server must not include a port (#{value}); the " \
                      'scripts append 3698/3700/3704 themselves'
            end

            value
        end

        def base_execution
            {
                'execution_name'  => @execution_name,
                'shift_server_ip' => @server,
                'shift_username'  => @username,
                'shift_password'  => @password
            }
        end

        def normalize_vm_details(vm_details)
            details = Array(vm_details).map {|vm| stringify(vm) }

            raise ArgumentError, ':vm_details must not be empty' if details.empty?

            details
        end

        def require_options!(options, *keys)
            missing = keys.reject do |key|
                value = options[key]
                value.respond_to?(:empty?) ? !value.empty? : !value.nil?
            end

            return if missing.empty?

            raise ArgumentError, "Missing required option(s): #{missing.join(', ')}"
        end

        # Deep convert symbol keys so callers can use either style.
        def stringify(value)
            case value
            when Hash
                value.each_with_object({}) {|(k, v), acc| acc[k.to_s] = stringify(v) }
            when Array
                value.map {|v| stringify(v) }
            else
                value
            end
        end

        def redact(value)
            case value
            when Hash
                value.each_with_object({}) do |(key, val), acc|
                    acc[key] = key.to_s.match?(/password|passwd|secret/i) ? '[redacted]' : redact(val)
                end
            when Array
                value.map {|v| redact(v) }
            else
                value
            end
        end

        # -------------------------- REST plumbing ------------------------- #

        # Open a session, yield its id, always end the session.
        def api_session
            response = api_request(Net::HTTP::Post, SESSION_PORT, '/api/tenant/session',
                                   :body => { 'loginId' => @username, 'password' => @password })

            sid = response.dig('session', '_id') || deep_find(response, '_id')

            raise OperationError, 'Shift session: no session id in response' if sid.nil?

            begin
                yield sid
            ensure
                begin
                    api_request(Net::HTTP::Post, SESSION_PORT, '/api/tenant/session/end',
                                :body => { 'sessionId' => sid }, :session => sid)
                rescue StandardError => e
                    @logger.warn("NetApp Shift: could not end session: #{e.message}")
                end
            end
        end

        # GET a paged setup collection and return its 'list'.
        def api_list(session_id, path)
            response = api_request(Net::HTTP::Get, SETUP_PORT, path, :session => session_id)

            Array(response['list'])
        end

        # GET a path on any service port, returning the parsed body as-is.
        # The recovery endpoints answer with a bare array rather than the
        # setup service's {'list' => [...]} envelope.
        def api_get(session_id, port, path)
            api_request(Net::HTTP::Get, port, path, :session => session_id)
        end

        def api_find_blueprint(session_id, blueprint_name)
            blueprints = api_list(session_id, '/api/setup/drplan')
            blueprint  = blueprints.find {|bp| bp['name'] == blueprint_name }

            if blueprint.nil?
                known = blueprints.map {|bp| bp['name'] }.compact
                raise OperationError,
                      "Blueprint '#{blueprint_name}' not found on #{@server}. " \
                      "Available blueprints: #{known.empty? ? '(none)' : known.join(', ')}"
            end

            blueprint
        end

        # One JSON request against the appliance. TLS verification is off to
        # match the Python (verify=False) -- Shift appliances ship self-signed
        # certificates.
        def api_request(method_class, port, path, body: nil, session: nil, timeout: 30)
            uri  = URI.parse("#{@server}:#{port}#{path}")
            http = Net::HTTP.new(uri.host, uri.port)

            http.use_ssl      = uri.scheme == 'https'
            http.verify_mode  = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
            http.open_timeout = timeout
            http.read_timeout = timeout

            request = method_class.new(uri.request_uri)
            request['Content-Type'] = 'application/json'
            request['netapp-sie-sessionid'] = session if session
            request.body = JSON.generate(body) if body

            response = http.request(request)

            unless response.is_a?(Net::HTTPSuccess)
                raise OperationError,
                      "Shift API #{path} returned #{response.code}: " \
                      "#{response.body.to_s[0, 200]}"
            end

            response.body.to_s.empty? ? {} : JSON.parse(response.body)
        rescue JSON::ParserError => e
            raise OperationError, "Shift API #{path} returned invalid JSON: #{e.message}"
        rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
            raise OperationError, "Shift API #{path} failed: #{e.class}: #{e.message}"
        end

        # First value for key anywhere in a nested structure (the session
        # response nests the id; mirrors the Python's parse_json search).
        def deep_find(obj, key)
            case obj
            when Hash
                return obj[key] if obj.key?(key)

                obj.each_value do |v|
                    found = deep_find(v, key)
                    return found unless found.nil?
                end
                nil
            when Array
                obj.each do |item|
                    found = deep_find(item, key)
                    return found unless found.nil?
                end
                nil
            end
        end

        # ------------------------ script plumbing ------------------------- #

        # Render the payload to the fixed path the script reads, run the block,
        # then put the original file back.
        #
        # The path comes from Config.yml and cannot be overridden per run, so
        # concurrent helpers would clobber each other -- hence the lock. The
        # file holds plaintext credentials while it exists, so it is written
        # 0600 and its previous mode is restored along with its contents.
        def with_payload(name, payload)
            path = File.join(@script_dir, "#{name}.json")

            lock(name) do
                original = File.exist?(path) ? File.binread(path) : nil
                mode     = File.exist?(path) ? File.stat(path).mode : nil

                begin
                    FileUtils.touch(path)
                    File.chmod(0o600, path)
                    File.write(path, JSON.pretty_generate(payload))

                    yield path
                ensure
                    if @keep_payload
                        @logger.warn("NetApp Shift: leaving #{path} in place; " \
                                     'it contains plaintext credentials')
                    elsif original
                        File.write(path, original)
                        File.chmod(mode, path) if mode
                    else
                        FileUtils.rm_f(path)
                    end
                end
            end
        end

        # Serialize helpers that share a script directory. The lock lives in
        # tmp so it never shows up as untracked noise in the submodule.
        def lock(name)
            key  = Digest::SHA256.hexdigest("#{@script_dir}/#{name}")[0, 16]
            path = File.join(Dir.tmpdir, "oneswap-shift-#{key}.lock")

            File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
                unless file.flock(File::LOCK_EX | File::LOCK_NB)
                    @logger.info("NetApp Shift: waiting for #{name} payload lock")
                    file.flock(File::LOCK_EX)
                end

                begin
                    yield
                ensure
                    file.flock(File::LOCK_UN)
                end
            end
        end

        # Run a script from the Python directory, streaming its output to the
        # log and enforcing a timeout.
        #
        # CWD matters twice over: the scripts import siblings (api_wrapper,
        # utils, conftest) and log_config creates its logs/ tree relative to
        # the working directory.
        #
        # Python's logging writes to stderr, so both streams are captured and
        # merged; get_site.py attaches a second StreamHandler and so logs
        # every line twice.
        #
        # @return [Array] [output, status, timed_out, duration]
        def execute(script, timeout)
            @logger.info("NetApp Shift: running #{script} (timeout #{timeout}s)")

            buffer    = +''
            mutex     = Mutex.new
            timed_out = false
            status    = nil
            t0        = Time.now

            Open3.popen3(@python, script,
                         :chdir => @script_dir,
                         :pgroup => true) do |stdin, out, err, wait_thr|
                stdin.close

                readers = [out, err].map do |io|
                    Thread.new do
                        io.each_line do |line|
                            mutex.synchronize { buffer << line }
                            @logger.debug("[shift] #{line.chomp}")
                        end
                    rescue IOError
                        nil
                    end
                end

                unless wait_thr.join(timeout)
                    timed_out = true
                    @logger.error("NetApp Shift: #{script} exceeded #{timeout}s, terminating")
                    kill_process_group(wait_thr.pid)
                end

                status = wait_thr.value

                readers.each {|thread| thread.join(5) }
                readers.each(&:kill)
            end

            [buffer, status, timed_out, (Time.now - t0).round(2)]
        end

        # Sends TERM then KILL to the process group led by pid.
        def kill_process_group(pid)
            Process.kill('TERM', -pid)
            sleep 5
            Process.kill('KILL', -pid)
        rescue Errno::ESRCH, Errno::EPERM
            nil
        end

        def log_result(result)
            if result.ok?
                @logger.info("NetApp Shift: #{result}")
            else
                @logger.error("NetApp Shift: #{result}")
                result.errors.each {|line| @logger.error("[shift] #{line}") }
            end
        end

        LOG_LINE = /^[\d\-]+ [\d:,]+ - \S+ - (?<level>\w+) - (?<message>.*)$/.freeze

        def error_lines(output)
            output.each_line.filter_map do |line|
                match = LOG_LINE.match(line.chomp)
                next unless match && match[:level] == 'ERROR'

                match[:message]
            end.uniq
        end

        # ------------------------------------------------------------------ #
        # Output scraping                                                     #
        #                                                                     #
        # The strings below are the log messages the upstream scripts emit on #
        # success. They are the only machine readable signal available, so    #
        # they need re-checking whenever the submodule is bumped.             #
        # ------------------------------------------------------------------ #

        def parse(operation, output)
            case operation
            when :get_site               then parse_get_site(output)
            when :create_blueprint       then parse_create_blueprint(output)
            when :run_compliance_check   then parse_compliance(output)
            when :trigger_migration      then parse_trigger_migration(output)
            when :check_migration_status then parse_migration_status(output)
            else { :ok => false }
            end
        end

        def parse_get_site(output)
            { :ok => output.include?('Site details fetched successfully') }
        end

        def parse_create_blueprint(output)
            id = output[/Blueprint created with id:\s*(\S+)/, 1]

            {
                :ok           => !id.nil?,
                :blueprint_id => id,
                :verified     => output.include?('Verified blueprint details:')
            }
        end

        def parse_compliance(output)
            task_id = output[/Compliance check initiated with task id:\s*(\S+)/, 1]
            result  = output[/Compliance check passed with result:\s*(.*)$/, 1]

            {
                :ok                 => !task_id.nil? && !result.nil?,
                :compliance_task_id => task_id,
                :compliance_result  => result
            }
        end

        # Shift refuses to execute a blueprint that already converted
        # successfully, with ERSCSTEX009 "No further execution is allowed".
        # That is not a failure for OneSwap -- the disks it needs are already
        # on the datastore -- so it is reported separately from :ok.
        ALREADY_EXECUTED = /ERSCSTEX009|No further execution is allowed/i.freeze

        def parse_trigger_migration(output)
            id = output[/Migration triggered for blueprint .* with execution id:\s*(\S+)/, 1]

            {
                :ok               => !id.nil?,
                :execution_id     => id,
                :already_executed => id.nil? && output.match?(ALREADY_EXECUTED)
            }
        end

        def parse_migration_status(output)
            status = output[/Status of Blueprint is (\S+) for blueprint/, 1]
            jobs   = output.include?('Job steps successfully completed for execution id')

            # verify_blueprint_status returns a real status only once it
            # contains "complete" or "error"; when its ~20 min polling window
            # runs out first it returns Python False, which the script logs as
            # the literal status "False" -- that means "still running", not
            # "failed". #wait_for_completion keys off :running to re-invoke.
            complete = status.to_s.include?('complete')
            running  = status.nil? || status == 'False'

            {
                :ok           => complete && jobs,
                :status       => status,
                :complete     => complete,
                :running      => running,
                :jobs_ok      => jobs,
                :failed_steps => output.scan(/Job step (.*) is not successful/).flatten.uniq
            }
        end

    end

end
