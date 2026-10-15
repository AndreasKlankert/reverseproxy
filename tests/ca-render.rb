require 'yaml'
require 'open3'
require 'tempfile'

def render(values)
  Tempfile.create(['proxy-ca-values', '.yaml']) do |file|
    file.write(YAML.dump(values))
    file.flush
    Open3.capture3('helm', 'template', 'test', 'charts/nexus-jar-proxy', '-f', file.path)
  end
end

bundle = "-----BEGIN CERTIFICATE-----\nrender-test-fixture\n-----END CERTIFICATE-----\n"
checksums = []
[{}, {'caConfigMap' => 'existing-ca'}, {'caBundle' => bundle}, {'caBundle' => bundle + "\n"}].each do |values|
  output, error, status = render({'nexus' => values})
  abort error unless status.success?
  docs = YAML.load_stream(output).compact
  deployment = docs.find { |d| d['kind'] == 'Deployment' }
  spec = deployment['spec']['template']['spec']
  container = spec['containers'][0]
  config = docs.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'test-config' }
  trust_path = values.empty? ? '/etc/ssl/certs/ca-certificates.crt' : '/ca/ca.crt'
  abort 'NGINX trust path mismatch' unless config['data']['nginx.conf.template'].include?("proxy_ssl_trusted_certificate #{trust_path};")
  abort 'Startup CA path mismatch' unless container['env'].find { |e| e['name'] == 'NEXUS_CA_FILE' }['value'] == trust_path
  ca_volume = spec['volumes'].find { |v| v['name'] == 'ca' }
  if values.empty?
    abort 'Unexpected CA volume' if ca_volume
  else
    name = values['caConfigMap'] || 'test-ca'
    abort 'Wrong CA ConfigMap' unless ca_volume['configMap']['name'] == name
    abort 'Wrong CA key projection' unless ca_volume['configMap']['items'] == [{'key' => 'ca.crt', 'path' => 'ca.crt'}]
    abort 'Missing CA mount' unless container['volumeMounts'].any? { |m| m['name'] == 'ca' && m['mountPath'] == '/ca' && m['readOnly'] }
  end
  if values['caBundle']
    ca = docs.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'test-ca' }
    abort 'CA content mismatch' unless ca['data']['ca.crt'].strip == values['caBundle'].strip
    checksums << deployment['spec']['template']['metadata']['annotations']['checksum/ca']
  end
end
abort 'CA changes do not trigger rollout' unless checksums.uniq.length == 2
[
  {'caConfigMap' => 'existing-ca', 'caBundle' => bundle},
  {'caConfigMap' => bundle},
  {'caBundle' => 'existing-ca'}
].each do |values|
  _, _, status = render({'nexus' => values})
  abort 'Invalid CA configuration accepted' if status.success?
end
puts 'CA rendering passed: system trust, existing and inline CA, mounts, rollout checksum and invalid values.'
