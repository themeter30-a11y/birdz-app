import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'sk.birdz.app',
  appName: 'Birdz',
  webDir: 'dist',
  server: {
    url: 'https://birdz.sk',
    cleartext: true,
    allowNavigation: ['birdz.sk', '*.birdz.sk', '*.google.com', '*.googleapis.com', '*.gstatic.com']
  },
  ios: {
    allowsLinkPreview: false,
    scrollEnabled: true,
    preferredContentMode: 'mobile'
  }
};

export default config;
