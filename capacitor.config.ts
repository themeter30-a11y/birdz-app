import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'sk.birdz.app',
  appName: 'Birdz',
  webDir: 'dist',
  server: {
    url: 'https://birdz.sk',
    cleartext: true
  },
  ios: {
    allowsLinkPreview: false,
    scrollEnabled: true,
  }
};

export default config;
