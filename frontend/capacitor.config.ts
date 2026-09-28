import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.bakedchicken77.bjjtelestrator',
  appName: 'Fresh Frame',
  webDir: 'dist',
  ios: {
    contentInset: 'never',
    preferredContentMode: 'mobile',
    backgroundColor: '#0b1015',
    allowsLinkPreview: false,
    scrollEnabled: false,
  },
};

export default config;
