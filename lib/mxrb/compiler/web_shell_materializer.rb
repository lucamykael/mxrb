# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module Compiler
    # Completes web templates normally hydrated by Studio Pro's proprietary build stage.
    class WebShellMaterializer
      PLACEHOLDER = /\{\{[a-z0-9_-]+\}\}/i

      def initialize(web, version:)
        @web = File.expand_path(web)
        @version = version.to_s
      end

      def materialize
        return 0 unless File.directory?(@web)

        changed = html_files.count { render_html(_1) }
        write_missing(File.join(@web, 'js', 'login_i18n.js'), login_i18n)
        write_missing(File.join(@web, 'lib', 'bootstrap', 'css', 'bootstrap.min.css'), login_styles)
        changed
      end

      private

      def html_files = Dir.glob(File.join(@web, '*.html')).sort

      def render_html(path)
        source = File.read(path)
        rendered = source.gsub('{{cachebust}}', "mxrb-#{@version}").gsub(PLACEHOLDER, '')
        return false if source == rendered

        File.write(path, rendered)
        true
      end

      def write_missing(path, contents)
        return if File.exist?(path)

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def login_i18n
        <<~JS
          window.i18nMap = {
            loginHeader: "Sign in", username: "User name", password: "Password",
            loginButton: "Sign in", goHomeButton: "Go home",
            http401: "The user name or password is incorrect.",
            http402: "The application license does not permit this sign-in.",
            http403: "Access is denied.", http404: "The application is unavailable.",
            http500: "The application encountered an error.",
            http503: "The application is starting. Try again shortly.",
            httpdefault: "Sign-in failed. Try again."
          };
        JS
      end

      def login_styles
        <<~CSS
          *{box-sizing:border-box}html,body{margin:0;font-family:Inter,Arial,sans-serif;color:#17212b}
          body{background:linear-gradient(135deg,#f4f8fb,#e6f1f6)}
          .form-group{margin-bottom:16px}.form-control{display:block;width:100%;height:42px;padding:10px 12px;
          border:1px solid #b8c5cf;border-radius:6px;background:#fff;font-size:14px;box-shadow:inset 0 1px 2px #0000000d}
          .form-control:focus{border-color:#0595db;outline:0;box-shadow:0 0 0 3px #0595db26}
          .btn{display:inline-block;padding:10px 18px;border:0;border-radius:6px;font-weight:600;cursor:pointer}
          .btn-primary{width:100%;color:#fff;background:#0595db}.btn-primary:hover{background:#087fb8}
          .btn[disabled]{cursor:not-allowed;opacity:.6}.alert{padding:10px 12px;margin-bottom:16px;border-radius:6px}
          .alert-danger{color:#842029;background:#f8d7da;border:1px solid #f5c2c7}
          .login-container{filter:drop-shadow(0 18px 35px #1c526626)}
          .login-form{background:#fff;border-radius:12px}.login-form label{display:block;margin-bottom:6px}
        CSS
      end
    end
  end
end
