import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5180,
    strictPort: true,
    // ABIs and deployment files live next to web/.
    fs: { allow: ['..'] },
  },
  preview: { port: 5180, strictPort: true },
})
