module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/librarian_web/**/*.*ex",
    "../lib/librarian_web/**/*.heex"
  ],
  theme: { extend: {} },
  plugins: [require("@tailwindcss/forms")]
}
