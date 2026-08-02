# frozen_string_literal: true

require 'fileutils'
require 'digest'

module Mxrb
  module Compiler
    # Completes web templates normally hydrated by Studio Pro's proprietary build stage.
    class WebShellMaterializer # rubocop:disable Metrics/ClassLength
      CACHE_REVISION = 6
      PLACEHOLDER = /\{\{[a-z0-9_-]+\}\}/i
      DYNAMIC_PAGE_CACHE = /
        (?:\(0,[A-Za-z0-9$_.]+\)\(\))\.getConfig\("isDevModeEnabled"\)\?"":
        `\?\$\{((?:\(0,[A-Za-z0-9$_.]+\)\(\))\.getConfig\("cachebust"\))\}`
      /x
      SELF_IMPORT = %r{import\*as\s+(?<binding>[A-Za-z_$][A-Za-z0-9_$]*)\s+from"\./(?<asset>[A-Za-z0-9_.-]+\.js)";
                        e\.C\(\k<binding>\),}x

      def initialize(web, version:)
        @web = File.expand_path(web)
        @version = version.to_s
      end

      def materialize
        return 0 unless File.directory?(@web)

        changed = html_files.count { render_html(_1) }
        changed += materialize_dynamic_imports
        write_missing(File.join(@web, 'js', 'login_i18n.js'), login_i18n)
        write_missing(File.join(@web, 'lib', 'bootstrap', 'css', 'bootstrap.min.css'), login_styles)
        changed
      end

      # React Client deliberately omits page cache tokens in developer mode. Native mxrb
      # rebuilds can then leave an already-open browser on an obsolete generated page.
      def materialize_dynamic_imports
        Dir.glob(File.join(@web, 'dist', '**', '*.js')).sort.count do |path|
          source = File.binread(path)
          rendered = render_javascript(source)
          next false if source == rendered

          write_versioned_chunk(path, rendered)
          true
        end
      end

      private

      def html_files = Dir.glob(File.join(@web, '*.html')).sort

      def render_javascript(source)
        rendered = source.gsub(DYNAMIC_PAGE_CACHE) do
          %(`?#{cache_token}\${#{Regexp.last_match(1)}}`)
        end
        rendered.gsub(SELF_IMPORT) do |match|
          asset = Regexp.last_match(:asset)
          match.sub(%("./#{asset}"), %("./#{asset}?#{cache_token}"))
        end
      end

      def render_html(path)
        source = File.read(path)
        rendered = source.gsub('{{cachebust}}', cache_token)
        rendered = rendered.gsub('{{unsupportedbrowser}}', unsupported_browser)
        rendered = rendered.gsub('{{themecss}}', theme_css)
        rendered = rendered.gsub('{{manifest}}', manifest)
        rendered = rendered.gsub(PLACEHOLDER, '')
        rendered = inject_navigation_compatibility(rendered) if File.basename(path) == 'index.html'
        return false if source == rendered

        File.write(path, rendered)
        true
      end

      # Runtime's manifest handler accepts an opaque decimal cache token only.
      def cache_token
        Digest::SHA256.hexdigest("mxrb:web-shell:#{CACHE_REVISION}:#{@version}")[0, 15].to_i(16).to_s
      end

      def write_versioned_chunk(path, rendered)
        old_stem = File.basename(path, '.js')
        return File.binwrite(path, rendered) unless old_stem.match?(/\A[0-9a-f]{16}\z/)

        new_stem = Digest::SHA256.hexdigest(rendered)[0, 16]
        rewrite_chunk_references(old_stem, new_stem)
        destination = File.join(File.dirname(path), "#{new_stem}.js")
        File.binwrite(destination, rendered)
        FileUtils.rm_f(path) unless destination == path
      end

      def rewrite_chunk_references(old_stem, new_stem)
        Dir.glob(File.join(@web, 'dist', '**', '*.js')).sort.each do |path|
          source = File.binread(path)
          rendered = source.gsub(old_stem, new_stem)
          File.binwrite(path, rendered) unless source == rendered
        end
      end

      def theme_css
        return '' unless File.file?(File.join(@web, 'theme.compiled.css'))

        %(<link rel="stylesheet" href="theme.compiled.css?#{cache_token}">)
      end

      def manifest
        %(<link rel="manifest" href="manifest.webmanifest?#{cache_token}" crossorigin="use-credentials">)
      end

      def inject_navigation_compatibility(html)
        return html if html.include?('data-mxrb-navigation-compat') || !html.include?('</head>')

        html.sub('</head>', "#{navigation_compatibility}\n</head>")
      end

      def navigation_compatibility # rubocop:disable Metrics/MethodLength
        <<~HTML.chomp
          <script data-mxrb-navigation-compat="#{CACHE_REVISION}">
            (() => {
              const install = () => {
                const ui = window.mx && window.mx.ui;
                if (!ui || typeof ui.openForm2 !== "function") return false;
                if (typeof ui.openForm !== "function") {
                  ui.openForm = (page, options, onLoad, onError) =>
                    Promise.resolve(ui.openForm2(
                      page, {}, undefined, undefined, options || { location: "content" }
                    )).then(onLoad, onError);
                }
                return true;
              };
              if (!install()) {
                const timer = window.setInterval(() => install() && window.clearInterval(timer), 50);
                window.setTimeout(() => window.clearInterval(timer), 60000);
              }
            })();
          </script>
        HTML
      end # rubocop:enable Metrics/MethodLength

      def unsupported_browser
        <<~HTML.chomp
          <script type="text/javascript">
            try { eval("async () => {}"); }
            catch (error) {
              var homeUrl = window.location.origin + window.location.pathname;
              var appUrl = homeUrl.slice(0, homeUrl.lastIndexOf("/") + 1);
              window.location.replace(appUrl + "unsupported-browser.html");
            }
          </script>
        HTML
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
    end # rubocop:enable Metrics/ClassLength
  end
end
