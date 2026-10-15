# frozen_string_literal: true

# How Mendix 11.12.1 hands a published REST operation its System.HttpRequest and
# System.HttpResponse: what the request reports (URI, version, content, headers)
# and how the status, reason, headers and content set on the response, or the
# value returned, make the HTTP response. requests.json lists the calls made.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Probe do
    page(:Home) { title 'REST HTTP messages' }
    microflow :Echo do
      parameter :id, type: :String
      parameter :q, type: :String
      parameter :httpRequest, type: object_of('System.HttpRequest')
      parameter :httpResponse, type: object_of('System.HttpResponse')
      retrieve_association :httpRequest, association: 'System.HttpHeaders', as: :headers
      list_operation :find_by_expression, :headers, expression: "toLowerCase($currentObject/Key) = 'x-probe'",
                                                    as: :probe
      create_variable :probeText, type: :String,
                                  value: "if $probe != empty then $probe/Key + ':' + $probe/Value else 'none'"
      change_object 'httpResponse', set: {
        'System.HttpResponse.StatusCode' => '201',
        'System.HttpResponse.ReasonPhrase' => "'Made'",
        'System.HttpMessage.Content' => "'id=' + $id + ';q=' + $q + ';uri=' + $httpRequest/Uri + " \
                                         "';version=' + $httpRequest/HttpVersion + ';probe=' + $probeText + " \
                                         "';content=' + $httpRequest/Content"
      }
      create_object 'System.HttpHeader', as: :echo do
        set 'System.HttpHeader.Key', to: "'X-Echo'"
        set 'System.HttpHeader.Value', to: "'yes'"
        set_association 'System.HttpHeaders', to: '$httpResponse'
      end
    end
    microflow :Redirect do
      parameter :httpResponse, type: object_of('System.HttpResponse')
      change_object 'httpResponse', set: { 'System.HttpResponse.StatusCode' => '302' }
      create_object 'System.HttpHeader', as: :location do
        set 'System.HttpHeader.Key', to: "'Location'"
        set 'System.HttpHeader.Value', to: "'/login?x=1'"
        set_association 'System.HttpHeaders', to: '$httpResponse'
      end
      create_object 'System.HttpHeader', as: :first do
        set 'System.HttpHeader.Key', to: "'Set-Cookie'"
        set 'System.HttpHeader.Value', to: "'nonce=abc; Path=/; HttpOnly'"
        set_association 'System.HttpHeaders', to: '$httpResponse'
      end
      create_object 'System.HttpHeader', as: :second do
        set 'System.HttpHeader.Key', to: "'Set-Cookie'"
        set 'System.HttpHeader.Value', to: "'other=1; Path=/'"
        set_association 'System.HttpHeaders', to: '$httpResponse'
      end
    end
    microflow :Both do
      parameter :httpResponse, type: object_of('System.HttpResponse')
      return_type :String
      change_object 'httpResponse', set: {
        'System.HttpResponse.StatusCode' => '202', 'System.HttpMessage.Content' => "'content'"
      }
      return_value "'returned'"
    end
    microflow :Defaults do
      parameter :httpResponse, type: object_of('System.HttpResponse')
      change_object 'httpResponse', set: {
        'System.HttpMessage.Content' => "'status=' + toString($httpResponse/StatusCode) + " \
                                        "';version=' + $httpResponse/HttpVersion"
      }
    end
    microflow :Created do
      parameter :httpResponse, type: object_of('System.HttpResponse')
      change_object 'httpResponse', set: {
        'System.HttpMessage.Content' => "'status=' + toString($httpResponse/StatusCode)"
      }
    end
    microflow :StatusOnly do
      parameter :httpResponse, type: object_of('System.HttpResponse')
      change_object 'httpResponse', set: { 'System.HttpResponse.StatusCode' => '404' }
    end
    microflow :Body do
      parameter :httpRequest, type: object_of('System.HttpRequest')
      return_type :String
      return_value "$httpRequest/Content + '|' + $httpRequest/Uri"
    end
    microflow :Plain do
      return_type :String
      return_value "'plain'"
    end
    published_rest_service :ProbeApi, path: 'rest/probe/v1', version: '1.0', requires_authentication: false do
      resource :probe do
        get :echo, path: 'echo/{id}', microflow: 'Probe.Echo'
        get :redirect, path: 'redirect', microflow: 'Probe.Redirect'
        get :both, path: 'both', microflow: 'Probe.Both'
        get :status_only, path: 'status-only', microflow: 'Probe.StatusOnly'
        get :defaults, path: 'defaults', microflow: 'Probe.Defaults'
        get :created, path: 'created', microflow: 'Probe.Created', success_status: :created
        post :body, path: 'body', microflow: 'Probe.Body'
        get :plain, path: 'plain', microflow: 'Probe.Plain'
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Probe.Home' }
end
# rubocop:enable Metrics/BlockLength
