/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Poppins', 'ui-sans-serif', 'system-ui', 'sans-serif'],
      },
      colors: {
        primary: {
          50: '#eef2fb',
          100: '#d9e1f5',
          200: '#b3c3ea',
          300: '#7f97d4',
          400: '#4a68b8',
          500: '#24438f',
          600: '#123378',
          700: '#00236a',
          800: '#001a52',
          900: '#00113a',
          DEFAULT: '#00236a',
        },
        accent: {
          50: '#fff6e6',
          100: '#ffe9c2',
          200: '#ffd284',
          300: '#ffb940',
          400: '#f9a51a',
          500: '#f39200',
          600: '#d07a00',
          700: '#a65f00',
          DEFAULT: '#f39200',
        },
        surface: '#f5f7fb',
      },
      boxShadow: {
        card: '0 1px 2px rgba(16, 24, 40, 0.04), 0 4px 16px rgba(16, 24, 40, 0.06)',
        soft: '0 1px 2px rgba(16, 24, 40, 0.06)',
      },
      borderRadius: {
        xl: '0.875rem',
        '2xl': '1.125rem',
      },
    },
  },
  plugins: [],
};
