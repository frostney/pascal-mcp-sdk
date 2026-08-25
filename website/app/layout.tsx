import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import { Provider } from '@/components/provider';
import { appName, siteUrl } from '@/lib/shared';
import './global.css';

const inter = Inter({
  subsets: ['latin'],
});

export const metadata: Metadata = {
  // Origin only — page-level URLs (canonical, OG images) carry the
  // GitHub Pages basePath themselves, so resolution keeps it intact.
  metadataBase: new URL(new URL(siteUrl).origin),
  title: {
    template: `%s | ${appName}`,
    default: appName,
  },
  description:
    'A FreePascal-native MCP (Model Context Protocol) server library with zero third-party dependencies.',
  openGraph: {
    siteName: appName,
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
  },
};

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" className={inter.className} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
