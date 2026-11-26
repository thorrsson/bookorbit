# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rubygems/package'
require 'stringio'
require 'tmpdir'
require_relative 'config'

class AzureDeploymentTest < Minitest::Test
  REPO = File.expand_path('../..', __dir__)

  def setup
    @tmp = Dir.mktmpdir('bookorbit-azure-test')
    @env_file = File.join(@tmp, '.env')
    AzureConfig.init_env(@env_file)
    @env = AzureConfig.read_env(@env_file).merge(
      'APP_URL' => 'https://books.example.com',
      'APP_IMAGE' => "ghcr.io/thorrsson/bookorbit@sha256:#{'1' * 64}",
      'POSTGRES_IMAGE' => "pgvector/pgvector:pg18@sha256:#{'2' * 64}",
      'CADDY_IMAGE' => "caddy:2-alpine@sha256:#{'3' * 64}"
    )
    write_env
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def write_env
    File.write(@env_file, @env.map { |key, value| "#{key}=#{value}\n" }.join)
  end

  def test_settings_are_private_and_init_never_overwrites_secrets
    assert_equal 0o600, File.stat(@env_file).mode & 0o777
    assert_raises(Errno::EEXIST) { AzureConfig.init_env(@env_file) }
    assert_equal @env['JWT_SECRET'], AzureConfig.read_env(@env_file)['JWT_SECRET']
    File.chmod(0o644, @env_file)
    assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
  end

  def test_mutable_images_interpolation_and_unknown_settings_fail_closed
    @env['APP_IMAGE'] = 'ghcr.io/thorrsson/bookorbit:latest'
    write_env
    assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
    File.write(@env_file, "POSTGRES_PASSWORD=$(touch /tmp/not-executed)\n")
    error = assert_raises(ArgumentError) { AzureConfig.read_env(@env_file) }
    refute_includes error.message, 'touch'
    write_env
    @env['COMPOSE_PROFILES'] = 'read-aloud'
    write_env
    assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
  end

  def test_vm_plan_rejects_unrestricted_ssh
    path = File.join(@tmp, 'vm.json')
    document = JSON.parse(File.read(File.join(REPO, 'infra/azure/vm.parameters.example.json')))
    document['parameters']['sshSourceCidr']['value'] = '0.0.0.0/0'
    File.write(path, JSON.generate(document))
    assert_raises(ArgumentError) { AzureConfig.parameters('vm', path, '-') }
  end

  def test_vm_tts_requires_a_pinned_cpu_image
    @env['COMPOSE_PROFILES'] = 'tts'
    ['', 'ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.0',
     "ghcr.io/remsky/kokoro-fastapi-gpu@sha256:#{'4' * 64}"].each do |image|
      @env['KOKORO_IMAGE'] = image
      write_env
      assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
    end
    @env['KOKORO_IMAGE'] = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.0@sha256:#{'4' * 64}"
    write_env
    assert_equal 'tts', AzureConfig.validate_env(@env_file, 'vm')['COMPOSE_PROFILES']
  end

  def test_vm_tts_settings_cannot_silently_disappear_in_container_apps
    @env['COMPOSE_PROFILES'] = 'tts'
    @env['KOKORO_IMAGE'] = "ghcr.io/remsky/kokoro-fastapi-cpu@sha256:#{'4' * 64}"
    write_env
    %w[container-app container-apps-platform].each do |target|
      error = assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, target) }
      assert_includes error.message, 'only for VM'
    end
    @env['COMPOSE_PROFILES'] = 'tts,read-aloud'
    write_env
    assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
  end

  def test_container_app_requires_verified_tls_and_preserves_runtime_secrets
    path = File.join(REPO, 'infra/azure/container-app.parameters.example.json')
    assert_raises(ArgumentError) { AzureConfig.parameters('container-app', path, @env_file) }
    @env['DATABASE_URL'] = "postgres://bookorbit:#{@env['POSTGRES_PASSWORD']}@target.postgres.database.azure.com/bookorbit?sslmode=no-verify"
    write_env
    assert_raises(ArgumentError) { AzureConfig.parameters('container-app', path, @env_file) }
    @env['DATABASE_URL'] = @env['DATABASE_URL'].sub('no-verify', 'verify-full')
    write_env
    params = AzureConfig.parameters('container-app', path, @env_file).fetch('parameters')
    assert_equal @env['JWT_SECRET'], params['jwtSecret']['value']
    assert_equal @env['EMAIL_ENCRYPTION_KEY'], params['emailEncryptionKey']['value']
    assert_equal @env['DATABASE_URL'], params['databaseUrl']['value']
    platform = File.join(REPO, 'infra/azure/container-apps-platform.parameters.example.json')
    platform_params = AzureConfig.parameters('container-apps-platform', platform, @env_file).fetch('parameters')
    assert_equal @env['POSTGRES_PASSWORD'], platform_params['postgresPassword']['value']
    assert_raises(ArgumentError) { AzureConfig.validate_env(@env_file, 'vm') }
  end

  def vm_compose_services
    FileUtils.cp(File.join(REPO, 'docker-compose.yml'), @tmp)
    FileUtils.cp(File.join(REPO, 'infra/azure/compose.vm.yml'), @tmp)
    stdout, stderr, status = Open3.capture3(
      'docker', 'compose', '--env-file', @env_file, '-f', File.join(@tmp, 'docker-compose.yml'),
      '-f', File.join(@tmp, 'compose.vm.yml'), 'config', '--format', 'json'
    )
    assert status.success?, stderr
    JSON.parse(stdout).fetch('services')
  end

  def test_compose_keeps_state_across_releases_and_exposes_only_the_proxy
    services = vm_compose_services
    refute services.key?('kokoro')
    assert_empty services['app'].fetch('ports', [])
    assert_empty services['postgres'].fetch('ports', [])
    assert_equal %w[80 443], services['proxy'].fetch('ports').map { |port| port['published'] }
    app_mounts = services['app']['volumes'].to_h { |mount| [mount['target'], mount['source']] }
    assert_equal '/srv/bookorbit/state/books', app_mounts['/books']
    assert_equal '/srv/bookorbit/state/app', app_mounts['/data']
    assert_equal @env['POSTGRES_IMAGE'], services['postgres']['image']
  end

  def test_vm_tts_profile_enables_private_health_checked_cpu_service
    @env['COMPOSE_PROFILES'] = 'tts'
    @env['KOKORO_IMAGE'] = "ghcr.io/remsky/kokoro-fastapi-cpu@sha256:#{'4' * 64}"
    write_env
    services = vm_compose_services
    kokoro = services.fetch('kokoro')
    assert_equal @env['KOKORO_IMAGE'], kokoro['image']
    assert_empty kokoro.fetch('ports', [])
    assert_includes kokoro.fetch('expose'), '8880'
    assert_equal services.fetch('app').fetch('networks').keys, kokoro.fetch('networks').keys
    assert_equal 'unless-stopped', kokoro['restart']
    assert_includes kokoro.fetch('healthcheck').fetch('test').join(' '), '/v1/audio/voices'
    assert_equal '5m0s', kokoro.fetch('healthcheck').fetch('start_period')
    assert_equal 1.0, kokoro['cpus']
    assert_equal 2 * 1024**3, Integer(kokoro.fetch('mem_limit'))
    assert_equal 256, kokoro['pids_limit']
    assert_equal 'false', kokoro.fetch('environment').fetch('USE_GPU')
    assert_equal 'cpu', kokoro.fetch('environment').fetch('DEVICE_TYPE')
    assert_equal '10m', kokoro.fetch('logging').fetch('options').fetch('max-size')
    refute services.key?('read-aloud-worker')
  end

  def test_templates_keep_managed_dependencies_private_and_bound_startup_probes
    built = ENV.fetch('BICEP_BUILD_DIR')
    app = JSON.parse(File.read(File.join(built, 'container-app.json')))
    %w[databaseUrl jwtSecret setupBootstrapToken emailEncryptionKey migrationEncryptionKey bookRequestEncryptionKey].each do |key|
      assert_equal 'securestring', app.fetch('parameters').fetch(key).fetch('type').downcase
    end
    template = app['resources'].find { |resource| resource['type'] == 'Microsoft.App/containerApps' }.fetch('properties').fetch('template')
    assert_equal({ 'minReplicas' => 1, 'maxReplicas' => 1 }, template['scale'])
    startup = template['containers'][0]['probes'].find { |probe| probe['type'] == 'Startup' }
    assert_operator startup['failureThreshold'], :<=, 10
    assert_operator startup['periodSeconds'] * startup['failureThreshold'], :>=, 1800
    platform = JSON.parse(File.read(File.join(built, 'container-apps-platform.json')))
    postgres = platform['resources'].find { |resource| resource['type'] == 'Microsoft.DBforPostgreSQL/flexibleServers' }
    assert_equal 'Disabled', postgres.dig('properties', 'network', 'publicNetworkAccess')
    storage = platform['resources'].find { |resource| resource['type'] == 'Microsoft.Storage/storageAccounts' }
    assert_equal 'Deny', storage.dig('properties', 'networkAcls', 'defaultAction')
    refute platform['resources'].any? { |resource| resource['type'] == 'Microsoft.App/containerApps' }
  end

  def setup_vm_transfer
    bin = File.join(@tmp, 'transfer-bin')
    FileUtils.mkdir_p(bin)
    @remote_stage = File.join(@tmp, 'remote-stage')
    @transfer_log = File.join(@tmp, 'transfer-log')
    real_tar = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
                  .map { |path| File.join(path, 'tar') }.find { |path| File.executable?(path) }
    File.write(File.join(bin, 'tar'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      require 'fileutils'
      require 'tmpdir'
      if ARGV.include?('-xf') || ENV['COPYFILE_DISABLE'] == '1'
        exec ENV.fetch('REAL_TAR'), *ARGV
      end
      Dir.mktmpdir('appledouble-test') do |archive|
        FileUtils.cp_r("#{ARGV.fetch(1)}/.", archive)
        File.write(File.join(archive, '._.env'), 'AppleDouble metadata')
        system(ENV.fetch('REAL_TAR'), '-C', archive, '-cf', '-', '.')
        exit $?.exitstatus
      end
    RUBY
    File.write(File.join(bin, 'ssh'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      require 'fileutils'
      command = ARGV.last
      stage = ENV.fetch('REMOTE_STAGE')
      case command
      when 'sudo cloud-init status --wait'
        exit 0
      when 'umask 077; mktemp -d /tmp/bookorbit.XXXXXXXXXX'
        FileUtils.mkdir(stage, mode: 0o700)
        puts '/tmp/bookorbit.test123'
      when /sudo bash/
        File.write(ENV.fetch('TRANSFER_LOG'), Dir.children(stage).sort.join("\n"))
        File.write(File.join(stage, 'unexpected'), 'retain') if ENV['EXTRA_STAGE_FILE'] == 'true'
        warn 'Installed release: test' if ENV.fetch('DEPLOY_EXIT', '0') == '0'
        exit ENV.fetch('DEPLOY_EXIT', '0').to_i
      else
        exec 'bash', '-c', command.gsub('/tmp/bookorbit.test123', stage)
      end
    RUBY
    File.write(File.join(bin, 'curl'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      exit ENV.fetch('HEALTH_EXIT', '0').to_i
    RUBY
    @transfer_env = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'REAL_TAR' => real_tar,
      'REMOTE_STAGE' => @remote_stage, 'TRANSFER_LOG' => @transfer_log,
      'COPYFILE_DISABLE' => nil
    }
  end

  def run_vm_transfer(overrides = {})
    Open3.capture3(
      @transfer_env.merge(overrides), 'bash', File.join(REPO, 'scripts/azure/azure.sh'),
      'deploy-vm', 'azureuser@test-host', @env_file
    )
  end

  def test_vm_transfer_omits_appledouble_metadata_and_removes_staging
    setup_vm_transfer
    stdout, stderr, status = run_vm_transfer
    assert status.success?, stderr
    assert_includes stdout, 'Deployment healthy'
    assert_equal %w[.env Caddyfile compose.vm.yml docker-compose.yml vm-host.sh].sort,
                 File.read(@transfer_log).split("\n")
    refute File.exist?(@remote_stage)
  end

  def test_vm_transfer_cleans_staging_and_preserves_deploy_and_health_failures
    setup_vm_transfer
    [{ 'DEPLOY_EXIT' => '17' }, { 'HEALTH_EXIT' => '35' }].each do |failure|
      stdout, stderr, status = run_vm_transfer(failure)
      assert_equal failure.values.first.to_i, status.exitstatus, stderr
      refute_includes stdout, 'Deployment healthy'
      refute File.exist?(@remote_stage)
    end
  end

  def test_vm_transfer_reports_cleanup_failure_without_deleting_unexpected_files
    setup_vm_transfer
    stdout, stderr, status = run_vm_transfer('EXTRA_STAGE_FILE' => 'true')
    refute status.success?
    assert_includes stdout, 'Deployment healthy'
    assert_includes stderr, 'Remote deployment cleanup failed'
    assert_equal ['unexpected'], Dir.children(@remote_stage)
  end

  def setup_host
    @host_root = File.join(@tmp, 'host')
    @previous = File.join(@host_root, 'releases', 'previous')
    FileUtils.mkdir_p([@previous, File.join(@host_root, 'backups')])
    FileUtils.cp(@env_file, File.join(@previous, '.env'))
    %w[docker-compose.yml compose.vm.yml Caddyfile].each { |file| File.write(File.join(@previous, file), '') }
    File.symlink(@previous, File.join(@host_root, 'current'))
    %w[books app postgres caddy-data caddy-config].each { |dir| FileUtils.mkdir_p(File.join(@host_root, 'state', dir)) }
    File.write(File.join(@host_root, 'state', 'books', 'test.epub'), 'test book')
    @bin = File.join(@tmp, 'bin')
    FileUtils.mkdir_p(@bin)
    { 'id' => "#!/bin/sh\necho 0\n", 'mountpoint' => "#!/bin/sh\nexit 0\n", 'flock' => "#!/bin/sh\nexit 0\n" }.each do |name, script|
      File.write(File.join(@bin, name), script, mode: 'w', perm: 0o755)
    end
    File.write(File.join(@bin, 'docker'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      File.open(ENV.fetch('COMMAND_LOG'), 'a') { |file| file.puts(ARGV.join('|')) }
      if ARGV.include?('exec')
        print 'database dump'
        exit 1 if ENV['FAIL_DUMP'] == 'true'
      elsif ARGV.include?('ps')
        puts 'app' unless ENV['APP_RUNNING'] == 'false'
      elsif ARGV.include?('up')
        exit 1 if ENV['FAIL_UP'] == 'true'
      end
    RUBY
    source = File.read(File.join(REPO, 'scripts/azure/vm-host.sh'))
    source = source.sub('root=/srv/bookorbit', "root=#{@host_root}")
    source = source.sub('/usr/local/sbin/bookorbit-vm', File.join(@tmp, 'installed-helper'))
    @host_script = File.join(@tmp, 'vm-host.sh')
    File.write(@host_script, source)
    @commands = File.join(@tmp, 'commands')
    @host_env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'COMMAND_LOG' => @commands }
  end

  def test_failed_predeploy_dump_cannot_be_mistaken_for_a_backup
    setup_host
    # Only the private staging path and host root are relocated for the test.
    stage = File.join(@tmp, 'stage')
    FileUtils.cp_r(@previous, stage)
    FileUtils.cp(@host_script, File.join(stage, 'vm-host.sh'))
    source = File.read(@host_script).sub('^/tmp/bookorbit\\.[a-zA-Z0-9]+$', "^#{Regexp.escape(stage)}$")
    File.write(@host_script, source)
    _stdout, stderr, status = Open3.capture3(@host_env.merge('FAIL_DUMP' => 'true'), 'bash', @host_script, 'deploy', stage)
    refute status.success?
    assert_includes stderr, 'backup failed'
    refute_includes File.read(@commands), '|up|'
    assert_includes File.read(@commands), '|start|app'
    assert_empty Dir.glob(File.join(@host_root, 'backups', '*', 'database.dump'))
    assert_equal @previous, File.readlink(File.join(@host_root, 'current'))
  end

  def test_export_is_streamed_and_cutover_does_not_restart_the_source
    setup_host
    stdout, stderr, status = Open3.capture3(@host_env, 'bash', @host_script, 'export', '--keep-stopped')
    assert status.success?, stderr
    entries = Gem::Package::TarReader.new(StringIO.new(stdout)).map(&:full_name)
    assert_includes entries, 'database.dump'
    assert_includes entries, 'books/test.epub'
    assert_includes entries, '.env'
    refute entries.any? { |entry| entry.start_with?('postgres/') }
    refute_includes File.read(@commands), '|start|app'
    assert_includes stderr, 'remains stopped'
  end

  def test_failed_upgrade_stops_the_new_app_without_restarting_an_old_image
    setup_host
    stage = File.join(@tmp, 'stage')
    FileUtils.cp_r(@previous, stage)
    FileUtils.cp(@host_script, File.join(stage, 'vm-host.sh'))
    source = File.read(@host_script).sub('^/tmp/bookorbit\\.[a-zA-Z0-9]+$', "^#{Regexp.escape(stage)}$")
    File.write(@host_script, source)
    _stdout, stderr, status = Open3.capture3(@host_env.merge('FAIL_UP' => 'true'), 'bash', @host_script, 'deploy', stage)
    refute status.success?
    assert_includes stderr, 'Migrations may have run'
    assert_includes File.read(@commands), '|up|'
    refute_includes File.read(@commands), '|start|app'
    assert_equal 2, File.read(@commands).lines.count { |line| line.include?('|stop|--timeout|60|app') }
    assert_equal @previous, File.readlink(File.join(@host_root, 'current'))
    assert_equal 1, Dir.glob(File.join(@host_root, 'backups', '*', 'database.dump')).size
  end

  def test_normal_export_does_not_restart_an_already_stopped_app
    setup_host
    _stdout, stderr, status = Open3.capture3(@host_env.merge('APP_RUNNING' => 'false'), 'bash', @host_script, 'export')
    assert status.success?, stderr
    refute_includes File.read(@commands), '|start|app'
  end

  def test_changed_credentials_block_deploy_before_any_container_changes
    setup_host
    stage = File.join(@tmp, 'stage')
    FileUtils.cp_r(@previous, stage)
    File.write(File.join(stage, '.env'), File.read(@env_file).sub(@env['JWT_SECRET'], 'f' * 64))
    source = File.read(@host_script).sub('^/tmp/bookorbit\\.[a-zA-Z0-9]+$', "^#{Regexp.escape(stage)}$")
    File.write(@host_script, source)
    stdout, stderr, status = Open3.capture3(@host_env, 'bash', @host_script, 'deploy', stage)
    refute status.success?
    assert_includes stderr, 'keys changed'
    refute File.exist?(@commands)
    refute_includes stdout + stderr, @env['JWT_SECRET']
  end

  def test_failed_export_resumes_a_previously_running_app
    setup_host
    stdout, stderr, status = Open3.capture3(@host_env.merge('FAIL_DUMP' => 'true'), 'bash', @host_script, 'export')
    refute status.success?, stderr
    assert_empty stdout
    assert_includes File.read(@commands), '|start|app'
  end

  def test_existing_active_container_revision_blocks_an_apply
    bin = File.join(@tmp, 'azure-bin')
    FileUtils.mkdir_p(bin)
    log = File.join(@tmp, 'azure-commands')
    File.write(File.join(bin, 'az'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      File.open(ENV.fetch('COMMAND_LOG'), 'a') { |file| file.puts(ARGV.join('|')) }
      puts 'true' if ARGV[0, 2] == ['group', 'exists']
      puts 'bookorbit' if ARGV[0, 2] == ['resource', 'list']
      puts 'bookorbit--active' if ARGV[0, 3] == ['containerapp', 'revision', 'list']
    RUBY
    @env['DATABASE_URL'] = "postgres://bookorbit:#{@env['POSTGRES_PASSWORD']}@target.postgres.database.azure.com/bookorbit?sslmode=verify-full"
    write_env
    stdout, stderr, status = Open3.capture3(
      { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'AZURE_SUBSCRIPTION_ID' => 'test-subscription', 'COMMAND_LOG' => log },
      'bash', File.join(REPO, 'scripts/azure/azure.sh'), 'apply', 'container-app', 'test-group',
      File.join(REPO, 'infra/azure/container-app.parameters.example.json'), @env_file, '--confirm-cutover'
    )
    refute status.success?
    assert_includes stderr, 'Deactivate ALL'
    refute_includes File.read(log), 'deployment|group|create'
    refute_includes stdout + stderr + File.read(log), @env['JWT_SECRET']
  end

  def test_certificate_bindings_survive_app_updates_unless_explicitly_changed
    parameters = File.join(@tmp, 'parameters.json')
    domains = File.join(@tmp, 'domains.json')
    binding = { 'name' => 'books.example.com', 'bindingType' => 'SniEnabled', 'certificateId' => '/certificates/managed' }
    File.write(parameters, JSON.generate('parameters' => {}))
    File.write(domains, JSON.generate([binding]))
    result = AzureConfig.preserve_domains(parameters, domains)
    assert_equal [binding], result['parameters']['customDomains']['value']
    File.write(parameters, JSON.generate('parameters' => { 'customDomains' => { 'value' => [] } }))
    assert_empty AzureConfig.preserve_domains(parameters, domains)['parameters']['customDomains']['value']
  end

  def test_domain_binding_requests_a_managed_certificate_and_verifies_https
    bin = File.join(@tmp, 'domain-bin')
    FileUtils.mkdir_p(bin)
    log = File.join(@tmp, 'domain-commands')
    File.write(File.join(bin, 'az'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      File.open(ENV.fetch('COMMAND_LOG'), 'a') { |file| file.puts(ARGV.join('|')) }
      puts '/subscriptions/test/resourceGroups/test/providers/Microsoft.App/managedEnvironments/bookorbit-apps' if ARGV[0, 2] == ['containerapp', 'show']
    RUBY
    File.write(File.join(bin, 'curl'), <<~'RUBY', mode: 'w', perm: 0o755)
      #!/usr/bin/env ruby
      File.open(ENV.fetch('COMMAND_LOG'), 'a') { |file| file.puts(['curl', *ARGV].join('|')) }
    RUBY
    @env['DATABASE_URL'] = "postgres://bookorbit:#{@env['POSTGRES_PASSWORD']}@target.postgres.database.azure.com/bookorbit?sslmode=verify-full"
    write_env
    stdout, stderr, status = Open3.capture3(
      { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'AZURE_SUBSCRIPTION_ID' => 'test', 'COMMAND_LOG' => log },
      'bash', File.join(REPO, 'scripts/azure/azure.sh'), 'bind-domain', 'test-group', 'bookorbit', @env_file
    )
    assert status.success?, stderr
    calls = File.read(log)
    assert_includes calls, 'hostname|bind'
    assert_includes calls, '--validation-method|CNAME'
    refute_includes calls, '--certificate|'
    assert_includes calls, 'https://books.example.com/api/v1/health'
    refute_includes calls, '--insecure'
    refute_includes stdout + stderr + calls, @env['POSTGRES_PASSWORD']
  end

  def test_failed_remote_export_is_not_published_as_a_complete_archive
    bin = File.join(@tmp, 'export-bin')
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, 'ssh'), "#!/bin/sh\nprintf 'incomplete stream'\nexit 1\n", mode: 'w', perm: 0o755)
    archive = File.join(@tmp, 'backup.tar')
    _stdout, stderr, status = Open3.capture3(
      { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}" }, 'bash', File.join(REPO, 'scripts/azure/azure.sh'),
      'export-vm', 'azureuser@host.example.com', archive
    )
    refute status.success?
    refute File.exist?(archive)
    assert File.exist?("#{archive}.partial")
    assert_equal 0o600, File.stat("#{archive}.partial").mode & 0o777
    assert_includes stderr, 'unverified'
  end
end
