package com.mendix.systemwideinterfaces.connectionbus.requests.types;

import com.mendix.systemwideinterfaces.connectionbus.requests.IRetrievalSchema;

/** A retrieve request. */
public interface IGetRequest {
	IRetrievalSchema getRetrievalSchema();
	void setRetrievalSchema(IRetrievalSchema schema);
}
