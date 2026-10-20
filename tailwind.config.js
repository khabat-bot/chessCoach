/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink: { 900: '#0b0f0e', 800: '#111715', 700: '#18201d', 600: '#222c28' },
        lime: { DEFAULT: '#7ef29d', dim: '#4fbf74' }
      },
      fontFamily: { sans: ['Inter', 'system-ui', 'sans-serif'] }
    }
  },
  plugins: []
};
