require 'tmpdir'
require 'fileutils'
require 'open3'

# Exercise the real startup script with isolated paths and stub image commands.
# NGINX itself is covered by smoke.sh.
Dir.mktmpdir('proxy-startup-') do |dir|
  bin = File.join(dir, 'bin')
  FileUtils.mkdir_p(bin)
  template = File.join(dir, 'template')
  config = File.join(dir, 'nginx.conf')
  ca_file = File.join(dir, 'ca.crt')
  File.write(ca_file, "-----BEGIN CERTIFICATE-----\ntest-fixture\n-----END CERTIFICATE-----\n")
  empty_ca = File.join(dir, 'empty-ca.crt')
  File.write(empty_ca, '')
  invalid_ca = File.join(dir, 'invalid-ca.crt')
  File.write(invalid_ca, 'ca-configmap-name')
  File.write(template, 'test configuration')
  File.write(File.join(bin, 'envsubst'), "#!/bin/sh\n/bin/cat\n")
  File.write(File.join(bin, 'nginx'), <<~SH)
    #!/bin/sh
    if [ "$1" = '-t' ]; then
      test "$2" = '-e' && test "$3" = 'stderr' || exit 90
      if [ "${TEST_NGINX_FAIL:-0}" = '1' ]; then
        printf '%s\n' 'simulated nginx configuration error' >&2
        exit 23
      fi
    else
      test "$1" = '-e' && test "$2" = 'stderr' || exit 91
    fi
  SH
  FileUtils.chmod(0755, Dir.glob("#{bin}/*"))
  source = File.read(File.expand_path('../charts/nexus-jar-proxy/files/start.sh', __dir__))
  source = source.gsub('/config/nginx.conf.template', template).gsub('/tmp/nginx.conf', config)
  script = File.join(dir, 'start.sh')
  File.write(script, source)
  env = {'PATH' => "#{bin}:/usr/bin:/bin", 'NEXUS_USERNAME' => 'test-reader',
         'NEXUS_PASSWORD' => 'test-secret-password', 'TEST_NGINX_FAIL' => '0',
         'NEXUS_CA_FILE' => ca_file}
  cases = [
    [{}, 0, 'proxy startup: starting nginx'],
    [{'NEXUS_USERNAME' => nil}, 1, 'Missing Nexus username'],
    [{'NEXUS_PASSWORD' => nil}, 1, 'Missing Nexus password'],
    [{'NEXUS_USERNAME' => 'invalid:reader'}, 1, 'must not contain a colon'],
    [{'PATH' => bin}, 1, 'required command missing: base64'],
    [{'NEXUS_CA_FILE' => File.join(dir, 'missing-ca.crt')}, 1, 'CA bundle is missing, unreadable or empty'],
    [{'NEXUS_CA_FILE' => empty_ca}, 1, 'CA bundle is missing, unreadable or empty'],
    [{'NEXUS_CA_FILE' => invalid_ca}, 1, 'CA bundle does not contain a PEM certificate'],
    [{'TEST_NGINX_FAIL' => '1'}, 23, 'stage=validating nginx configuration exit=23']
  ]
  cases.each do |overrides, exit_code, message|
    stdout, stderr, status = Open3.capture3(env.merge(overrides), '/bin/sh', script)
    abort "Wrong exit status: #{status.exitstatus}; #{stderr}" unless status.exitstatus == exit_code
    abort "Missing diagnostic: #{message}" unless stderr.include?(message)
    abort 'Credential leaked into logs' if (stdout + stderr).include?(env['NEXUS_PASSWORD'])
  end
  File.unlink(template)
  _, stderr, status = Open3.capture3(env, '/bin/sh', script)
  abort 'Missing template accepted' if status.success?
  abort 'Missing render failure diagnostic' unless stderr.include?('stage=rendering configuration')
end
puts 'Startup diagnostics passed: success, missing credentials/tools/template, invalid CA files and nginx validation failure.'
