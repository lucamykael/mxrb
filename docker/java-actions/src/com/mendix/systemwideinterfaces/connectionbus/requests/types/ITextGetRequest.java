package com.mendix.systemwideinterfaces.connectionbus.requests.types;

import com.mendix.systemwideinterfaces.connectionbus.requests.IParameterMap;

/** A retrieve request in a query language, with parameters. */
public interface ITextGetRequest extends IGetRequest {
	String getQuery();
	void setQuery(String query);
	void setParameters(IParameterMap parameters);
	IParameterMap createParameterMap();
	IParameterMap getParameters();
}
