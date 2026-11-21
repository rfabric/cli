// Stub of every CI provider endpoint the wrapper tests need, on one local port; logs each
// request as one JSON line ({method, url, token, body}; token: the bearer or GitLab private
// token) to the log file.
//
//   node stub.mjs <port> <log file> <auth URL>
//
// - OpenID Connect issuer http://127.0.0.1:<port>: /.well-known/openid-configuration and
//   /.well-known/jwks (an RS256 key generated at start).
// - GET /mint?claims=<json>: a signed identity token (aud: the auth service's issuer) with the
//   claims (GitLab RFABRIC_ID_TOKEN, Bitbucket BITBUCKET_STEP_OIDC_TOKEN).
// - GET /github-id-token?audience=<aud>: GitHub's ACTIONS_ID_TOKEN_REQUEST_URL answer
//   {"value": <token>} with GitHub claims, bearer `github-request-token` required.
// - GitHub REST: list, create and update issue comments (/repos/<owner>/<repo>/issues/...);
//   repository acme/fork answers 403 to writes (a fork pull request's read-only token).
// - GitLab REST: the token's user (/api/v4/user); list, create and update merge request notes
//   (/api/v4/projects/.../notes).
// - Bitbucket REST: list and create pull request comments (/bitbucket/2.0/...).
// - Bitbucket Pipelines proxy: requests to http://api.bitbucket.org/... answer 200.
//
// Each comment records its author, the user of the token that created it; only its author may
// update it (403 otherwise). The tokens: the wrappers' (`job-token`, `gitlab-token`,
// `bitbucket-token`) and `other-token`, a reviewer on GitHub and GitLab.
import { createSign, generateKeyPairSync, randomUUID } from 'node:crypto'
import { appendFileSync } from 'node:fs'
import { createServer } from 'node:http'

const [port, logFile, authUrl] = process.argv.slice(2)
const issuer = `http://127.0.0.1:${port}`
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
// A fresh key id per start: the auth service caches an issuer's keys by key id.
const kid = `stub-${randomUUID()}`
const jwk = { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' }
const audience = (await (await fetch(`${authUrl}/.well-known/oauth-authorization-server`)).json()).issuer

const base64url = value => Buffer.from(value).toString('base64url')
function mint(claims) {
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT' }))
  const payload = base64url(JSON.stringify({ iss: issuer, aud: audience, iat: now, nbf: now, exp: now + 300, ...claims }))
  const signature = createSign('RSA-SHA256').update(`${header}.${payload}`).sign(privateKey).toString('base64url')
  return `${header}.${payload}.${signature}`
}

const githubClaims = { sub: 'repo:acme/robot:pull_request', repository: 'acme/robot', repository_id: '123456789', ref: 'refs/pull/42/merge' }
// Per provider: the comment field naming its author, the user each token acts as, the comments.
const providers = {
  github: {
    author: 'user',
    users: { 'job-token': { login: 'github-actions[bot]' }, 'other-token': { login: 'octocat' } },
    comments: [],
  },
  gitlab: {
    author: 'author',
    users: { 'gitlab-token': { id: 77, username: 'project_4242_bot' }, 'other-token': { id: 78, username: 'reviewer' } },
    comments: [],
  },
  bitbucket: {
    author: 'user',
    users: { 'bitbucket-token': { uuid: '{6f1d3c55-0a51-4c1e-9b0e-6a3e2d1f0c11}' } },
    comments: [],
  },
}
let nextId = 1

function answer(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(typeof body === 'string' ? body : JSON.stringify(body))
}

function user(response, provider, token) {
  const found = providers[provider].users[token]
  return found ? answer(response, 200, found) : answer(response, 401, {})
}

function comments(response, method, provider, token, id, body, wrap) {
  const { author, users, comments: store } = providers[provider]
  const actor = users[token]
  if (!actor) return answer(response, 401, {})
  if (method === 'GET') return answer(response, 200, wrap(store))
  if (method === 'POST') {
    const entry = { id: nextId++, ...body, [author]: actor }
    store.push(entry)
    return answer(response, 201, entry)
  }
  const entry = store.find(candidate => candidate.id === Number(id))
  if (!entry) return answer(response, 404, {})
  if (entry[author] !== actor) return answer(response, 403, { message: 'only the author may update a comment' })
  Object.assign(entry, body)
  return answer(response, 200, entry)
}

createServer((request, response) => {
  let raw = ''
  request.on('data', chunk => (raw += chunk))
  request.on('end', () => {
    const body = raw ? JSON.parse(raw) : null
    const token = request.headers['private-token'] ?? request.headers.authorization?.replace(/^Bearer /, '') ?? null
    appendFileSync(logFile, `${JSON.stringify({ method: request.method, url: request.url, token, body })}\n`)
    const url = new URL(request.url, issuer)
    const path = url.pathname
    let match
    if (request.url.startsWith('http://api.bitbucket.org/')) return answer(response, 200, {})
    if (path === '/.well-known/openid-configuration') return answer(response, 200, { issuer, jwks_uri: `${issuer}/.well-known/jwks` })
    if (path === '/.well-known/jwks') return answer(response, 200, { keys: [jwk] })
    if (path === '/mint') return answer(response, 200, mint(JSON.parse(url.searchParams.get('claims') ?? '{}')))
    if (path === '/github-id-token') {
      if (request.headers.authorization !== 'Bearer github-request-token') return answer(response, 401, {})
      return answer(response, 200, { value: mint({ ...githubClaims, aud: url.searchParams.get('audience') }) })
    }
    if ((match = path.match(/^\/repos\/([^/]+\/[^/]+)\/issues\/(?:\d+\/comments|comments\/(\d+))$/))) {
      if (request.method !== 'GET' && match[1] === 'acme/fork') return answer(response, 403, { message: 'Resource not accessible by integration' })
      return comments(response, request.method, 'github', token, match[2], body, list => list)
    }
    if (path === '/api/v4/user') return user(response, 'gitlab', token)
    if ((match = path.match(/^\/api\/v4\/projects\/\d+\/merge_requests\/\d+\/notes(?:\/(\d+))?$/))) {
      return comments(response, request.method, 'gitlab', token, match[1], body, list => list)
    }
    if (path.match(/^\/bitbucket\/2\.0\/repositories\/[^/]+\/[^/]+\/pullrequests\/\d+\/comments$/)) {
      return comments(response, request.method, 'bitbucket', token, null, body, list => ({ values: list }))
    }
    return answer(response, 404, {})
  })
}).listen(Number(port), '127.0.0.1', () => console.log(`stub ${issuer}`))
