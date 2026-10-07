import http from 'node:http';

const auth = `Basic ${Buffer.from('reader:p:a$$word').toString('base64')}`;
const artifact = Buffer.from('504b030400ff0a0d804a4152', 'hex');
const rootPath = (process.env.MOCK_ROOT_PATH || '/').replace(/\/$/, '') + '/';

http.createServer((req, res) => {
  if (req.headers.authorization !== auth) {
    res.writeHead(401).end();
    return;
  }
  if (req.headers.cookie || req.headers['x-client-secret']) {
    res.writeHead(400).end();
    return;
  }
  if (!req.url.startsWith(rootPath)) {
    res.writeHead(400).end();
    return;
  }
  req.url = '/' + req.url.slice(rootPath.length);
  if (req.url === '/admin') {
    res.writeHead(418).end();
    return;
  }
  if (req.url === '/repository/maven-public/missing.jar') {
    res.writeHead(404).end();
    return;
  }
  if (req.url === '/repository/maven-public/forbidden.jar') {
    res.writeHead(403).end();
    return;
  }
  if (req.url === '/repository/maven-public/redirect.jar') {
    res.writeHead(302, { Location: `http://nexus:8081${rootPath}repository/maven-public/driver.jar?download=1` }).end();
    return;
  }
  const driverBodies = {
    '/driver/jar1?download=1': artifact,
    '/driver/jar2?download=1': Buffer.concat([artifact, Buffer.from('jar2')]),
    '/irgendwas/nested/jar1?download=1': artifact,
  };
  const requestedArtifact = req.url === '/repository/maven-public/driver.jar?download=1'
    ? artifact : driverBodies[req.url];
  if (!requestedArtifact) {
    res.writeHead(404).end();
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    // If a write request reaches Nexus, the smoke test must fail.
    res.writeHead(500).end();
    return;
  }
  if (req.headers['if-none-match'] === '"driver-v1"') {
    res.writeHead(304, { ETag: '"driver-v1"' }).end();
    return;
  }
  const range = req.headers.range === 'bytes=0-3';
  const body = range ? requestedArtifact.subarray(0, 4) : requestedArtifact;
  res.writeHead(range ? 206 : 200, {
    'Content-Type': 'application/java-archive',
    'Content-Length': body.length,
    'Accept-Ranges': 'bytes',
    ETag: '"driver-v1"',
    ...(range ? { 'Content-Range': `bytes 0-3/${requestedArtifact.length}` } : {}),
  });
  res.end(req.method === 'HEAD' ? undefined : body);
}).listen(8081, '0.0.0.0');
