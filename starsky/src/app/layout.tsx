import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Starsky for Neovim · Next.js TypeScript Webclient & :Clina AI Coding IDE",
  description:
    "Next.js TypeScript webclient for installer.nvim featuring the :Clina TypeScript AI Coding IDE, SFTP Studio UI, 601 Mason Servers, and lazy.nvim Spec Saver.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
