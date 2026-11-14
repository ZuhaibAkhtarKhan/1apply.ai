import path from "node:path";

import type { NextConfig } from "next";

// Docker builds set NEXT_OUTPUT=standalone to get a self-contained server bundle.
// The EC2/PM2 deploy leaves it unset and keeps using `next start`.
const standalone = process.env.NEXT_OUTPUT === "standalone";

const nextConfig: NextConfig = {
  ...(standalone
    ? {
        output: "standalone" as const,
        // Monorepo: trace workspace packages from the repo root (build runs with cwd = apps/web).
        outputFileTracingRoot: path.resolve(process.cwd(), "../.."),
      }
    : {}),
  transpilePackages: ["@1apply/contracts", "@1apply/domain", "@1apply/form-engine"],
  serverExternalPackages: ["mammoth", "playwright"],
  poweredByHeader: false,
  eslint: {
    // On 2GB EC2, run lint separately; build uses scripts/ec2-build.sh
    ignoreDuringBuilds: process.env.LOW_MEM_BUILD === "1",
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
