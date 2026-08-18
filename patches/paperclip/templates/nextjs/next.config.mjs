/** @type {import('next').NextConfig} */
const nextConfig = {
  // Next 16 rejects any dev request carrying an Origin header unless the host
  // is localhost or listed here — a SAME-origin request from
  // http://<host>:<port> still 403s. The preview is published on a non-local
  // host, so without this the page loads and every JS chunk fails.
  // DEV_HOST comes from the devenv lease, so this stays correct wherever the
  // preview is published.
  allowedDevOrigins: [process.env.DEV_HOST, process.env.DEV_URL]
    .filter(Boolean)
    .map((v) => v.replace(/^https?:\/\//, "").replace(/\/.*$/, "")),
  // pg and ioredis have dynamic internals; keep them out of the bundler.
  serverExternalPackages: ["pg", "ioredis"],
};

export default nextConfig;
