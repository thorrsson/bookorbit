#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ipaddr'
require 'json'
require 'securerandom'
require 'uri'

module AzureConfig
  module_function

  def read_env(path)
    raise ArgumentError, 'Runtime settings must have owner-only permissions (chmod 600).' unless (File.stat(path).mode & 0o077).zero?

    File.readlines(path, chomp: true).each_with_index.each_with_object({}) do |(line, index), result|
      next if line.strip.empty? || line.lstrip.start_with?('#')

      match = /\A([A-Z][A-Z0-9_]*)=([^\s$`'"\\#]*)\z/.match(line)
      raise ArgumentError, "Invalid runtime setting at line #{index + 1}; use plain KEY=value without shell interpolation." unless match
      raise ArgumentError, "Duplicate runtime setting: #{match[1]}." if result.key?(match[1])

      result[match[1]] = match[2]
    end
  end

  def validate_env(path, target)
    env = read_env(path)
    supported = %w[APP_IMAGE POSTGRES_IMAGE CADDY_IMAGE APP_URL CLIENT_URL POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
                   JWT_SECRET SETUP_BOOTSTRAP_TOKEN EMAIL_ENCRYPTION_KEY MIGRATION_ENCRYPTION_KEY BOOK_REQUEST_ENCRYPTION_KEY
                   PUID PGID NODE_MAX_OLD_SPACE_SIZE DATABASE_URL COMPOSE_PROFILES KOKORO_IMAGE]
    unknown = env.keys - supported
    raise ArgumentError, "Unsupported runtime settings: #{unknown.join(', ')}. Only the core stack and VM Kokoro TTS are supported." unless unknown.empty?
    profiles = env.fetch('COMPOSE_PROFILES', '')
    kokoro_image = env.fetch('KOKORO_IMAGE', '')
    raise ArgumentError, 'COMPOSE_PROFILES must be empty or tts; other optional workers are not supported.' unless ['', 'tts'].include?(profiles)
    if target != 'vm' && (!profiles.empty? || !kokoro_image.empty?)
      raise ArgumentError, 'COMPOSE_PROFILES and KOKORO_IMAGE are supported only for VM deployments; remove them for Container Apps.'
    end
    image_keys = %w[APP_IMAGE POSTGRES_IMAGE CADDY_IMAGE]
    image_keys << 'KOKORO_IMAGE' if profiles == 'tts' || !kokoro_image.empty?
    image_keys.each do |key|
      raise ArgumentError, "#{key} must be pinned with @sha256 and a complete digest." unless
        /\A[a-z0-9][a-z0-9._:\/-]*@sha256:[a-f0-9]{64}\z/.match?(env.fetch(key, ''))
    end
    unless kokoro_image.empty? || /\Aghcr\.io\/remsky\/kokoro-fastapi-cpu(?::[a-z0-9._-]+)?@sha256:/.match?(kokoro_image)
      raise ArgumentError, 'KOKORO_IMAGE must use ghcr.io/remsky/kokoro-fastapi-cpu, not a GPU image.'
    end
    raise ArgumentError, 'POSTGRES_IMAGE must use pgvector/pgvector:pg18, not a different database major.' unless
      env['POSTGRES_IMAGE'].start_with?('pgvector/pgvector:pg18@')

    { 'POSTGRES_PASSWORD' => 48, 'JWT_SECRET' => 64, 'SETUP_BOOTSTRAP_TOKEN' => 32 }.each do |key, length|
      raise ArgumentError, "#{key} must contain at least #{length} hexadecimal characters." unless
        /\A[a-fA-F0-9]{#{length},}\z/.match?(env.fetch(key, ''))
    end
    %w[EMAIL_ENCRYPTION_KEY MIGRATION_ENCRYPTION_KEY BOOK_REQUEST_ENCRYPTION_KEY].each do |key|
      value = env.fetch(key, '')
      raise ArgumentError, "#{key} must be empty or exactly 64 hexadecimal characters." unless value.empty? || /\A[a-fA-F0-9]{64}\z/.match?(value)
    end
    %w[POSTGRES_USER POSTGRES_DB].each do |key|
      raise ArgumentError, "#{key} must be a lowercase PostgreSQL identifier." unless /\A[a-z][a-z0-9_]{0,62}\z/.match?(env.fetch(key, ''))
    end
    raise ArgumentError, 'APP_URL must be an HTTPS DNS hostname without a path, query or nonstandard port.' unless
      /\Ahttps:\/\/[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}(?::443)?\z/.match?(env.fetch('APP_URL', ''))
    raise ArgumentError, 'CLIENT_URL must match APP_URL for the single-origin deployment.' unless env.fetch('CLIENT_URL', env['APP_URL']) == env['APP_URL']
    %w[PUID PGID].each do |key|
      raise ArgumentError, "#{key} must be a positive numeric UID/GID." unless /\A[1-9][0-9]*\z/.match?(env.fetch(key, '1000'))
    end
    heap = env.fetch('NODE_MAX_OLD_SPACE_SIZE', '2048')
    raise ArgumentError, 'NODE_MAX_OLD_SPACE_SIZE must be a positive number of MB.' unless /\A[1-9][0-9]*\z/.match?(heap)

    if target == 'container-app' || (target == 'container-apps-platform' && !env.fetch('DATABASE_URL', '').empty?)
      url = URI.parse(env.fetch('DATABASE_URL', ''))
      raise ArgumentError, 'DATABASE_URL must use managed PostgreSQL with sslmode=verify-full.' unless
        %w[postgres postgresql].include?(url.scheme) && url.host&.end_with?('.postgres.database.azure.com') &&
        url.user && url.password && URI.decode_www_form(url.query.to_s).to_h['sslmode'] == 'verify-full'
      if target == 'container-app' && !(128..3072).cover?(heap.to_i)
        raise ArgumentError, 'Container Apps heap must fit the 4 GiB container (128-3072 MB).'
      end
    elsif target == 'vm' && !env.fetch('DATABASE_URL', '').empty?
      raise ArgumentError, 'Remove DATABASE_URL for the VM/local PostgreSQL deployment.'
    end
    env
  rescue URI::InvalidURIError
    raise ArgumentError, 'DATABASE_URL is not a valid PostgreSQL URL.'
  end

  def parameters(target, path, env_path)
    document = JSON.parse(File.read(path))
    params = document.fetch('parameters')
    name = params.fetch('name', {}).fetch('value', 'bookorbit')
    raise ArgumentError, 'name must be 3-15 lowercase letters/digits/hyphens, beginning with a letter and ending with a letter/digit.' unless
      /\A[a-z][a-z0-9-]{1,13}[a-z0-9]\z/.match?(name) && !name.include?('--')

    additions = {}
    if target == 'vm'
      cidr = params.fetch('sshSourceCidr').fetch('value')
      address = IPAddr.new(cidr)
      raise ArgumentError, 'sshSourceCidr must be an IPv4 CIDR of /24 or narrower.' unless address.ipv4? && cidr.include?('/') && address.prefix >= 24
      raise ArgumentError, 'sshPublicKey must contain a public SSH key.' unless
        /\A(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+\/=]+(?: .*)?\z/.match?(params.fetch('sshPublicKey').fetch('value'))
    else
      env = validate_env(env_path, target)
      additions = if target == 'container-apps-platform'
                    {
                      'postgresPassword' => env.fetch('POSTGRES_PASSWORD'),
                      'postgresUser' => env.fetch('POSTGRES_USER'),
                      'postgresDatabase' => env.fetch('POSTGRES_DB')
                    }
                  elsif target == 'container-app'
                    {
                      'appImage' => env.fetch('APP_IMAGE'), 'appUrl' => env.fetch('APP_URL'),
                      'databaseUrl' => env.fetch('DATABASE_URL'), 'jwtSecret' => env.fetch('JWT_SECRET'),
                      'setupBootstrapToken' => env.fetch('SETUP_BOOTSTRAP_TOKEN'),
                      'emailEncryptionKey' => env.fetch('EMAIL_ENCRYPTION_KEY', ''),
                      'migrationEncryptionKey' => env.fetch('MIGRATION_ENCRYPTION_KEY', ''),
                      'bookRequestEncryptionKey' => env.fetch('BOOK_REQUEST_ENCRYPTION_KEY', ''),
                      'puid' => env.fetch('PUID', '1000'), 'pgid' => env.fetch('PGID', '1000'),
                      'nodeMaxOldSpaceSize' => env.fetch('NODE_MAX_OLD_SPACE_SIZE', '2048').to_i
                    }
                  else
                    raise ArgumentError, 'Unknown deployment target.'
                  end
    end
    additions.each { |key, value| params[key] = { 'value' => value } }
    document
  rescue IPAddr::InvalidAddressError
    raise ArgumentError, 'sshSourceCidr is not a valid IPv4 CIDR.'
  end

  def init_env(path)
    contents = <<~ENV
      # Resolve these image tags to digests before deploying. See docs/AZURE.md.
      APP_IMAGE=ghcr.io/thorrsson/bookorbit@sha256:REPLACE
      POSTGRES_IMAGE=pgvector/pgvector:pg18@sha256:REPLACE
      CADDY_IMAGE=caddy@sha256:REPLACE
      APP_URL=https://library.the3littlesisters.com
      POSTGRES_USER=bookorbit
      POSTGRES_DB=bookorbit
      POSTGRES_PASSWORD=#{SecureRandom.hex(24)}
      JWT_SECRET=#{SecureRandom.hex(32)}
      SETUP_BOOTSTRAP_TOKEN=#{SecureRandom.hex(16)}
      EMAIL_ENCRYPTION_KEY=#{SecureRandom.hex(32)}
      MIGRATION_ENCRYPTION_KEY=#{SecureRandom.hex(32)}
      BOOK_REQUEST_ENCRYPTION_KEY=#{SecureRandom.hex(32)}
      PUID=1000
      PGID=1000
      NODE_MAX_OLD_SPACE_SIZE=2048
      # Optional VM narration: set COMPOSE_PROFILES=tts and pin the Kokoro CPU image.
      COMPOSE_PROFILES=
      KOKORO_IMAGE=
    ENV
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
  end

  def preserve_domains(parameters_path, domains_path)
    document = JSON.parse(File.read(parameters_path))
    domains = JSON.parse(File.read(domains_path)) || []
    raise ArgumentError, 'Expected a list of existing custom domains.' unless domains.is_a?(Array)

    document.fetch('parameters')['customDomains'] ||= {
      'value' => domains.map do |domain|
        domain.select { |key, value| %w[name bindingType certificateId].include?(key) && !value.nil? }
      end
    }
    document
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command, *args = ARGV
    case command
    when 'init-env'
      AzureConfig.init_env(args.fetch(0))
    when 'validate-env'
      puts AzureConfig.validate_env(args.fetch(0), 'vm').fetch('APP_URL')
    when 'parameters'
      puts JSON.generate(AzureConfig.parameters(*args))
    when 'hostname'
      puts URI.parse(AzureConfig.validate_env(args.fetch(0), 'container-app').fetch('APP_URL')).host
    when 'preserve-domains'
      puts JSON.generate(AzureConfig.preserve_domains(*args))
    else
      raise ArgumentError, 'Unknown configuration command.'
    end
  rescue JSON::ParserError
    warn 'Azure configuration failed: invalid JSON parameters.'
    exit 1
  rescue ArgumentError, KeyError, SystemCallError => e
    warn "Azure configuration failed: #{e.message}"
    exit 1
  end
end
