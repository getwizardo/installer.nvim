import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  allowedDevOrigins: [
    "*.e2b.app",
    "http://*.e2b.app",
    "https://*.e2b.app",
    "localhost",
    "127.0.0.1",
  ],
};

export default nextConfig;
