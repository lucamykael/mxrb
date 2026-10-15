package com.mendix.integration;

/** A SOAP fault a web service operation reports. */
public class WebserviceException extends Exception {
	private static final long serialVersionUID = 1L;

	public static final String clientFaultCode = "Client";
	public static final String serverFaultCode = "Server";

	private final String faultCode;

	public WebserviceException(String faultCode, String faultString) {
		super(faultString);
		this.faultCode = faultCode;
	}

	public String getFaultCode() {
		return faultCode;
	}

	public String getFaultString() {
		return getMessage();
	}
}
