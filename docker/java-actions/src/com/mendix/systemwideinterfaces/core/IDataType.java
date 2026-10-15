package com.mendix.systemwideinterfaces.core;

import com.mendix.systemwideinterfaces.core.meta.IMetaEnumeration;

/** The type of a microflow parameter or result, or of an attribute. */
public interface IDataType {
	/** The kinds of type. */
	enum DataTypeEnum {
		Object, Enumeration, Integer, Long, Decimal, Boolean, Datetime, String, HashString, AutoNumber, Binary,
		Nothing, Unknown, AnyObject
	}

	DataTypeEnum getType();
	String getObjectType();
	boolean isList();
	boolean isMendixObject();
	boolean isNothing();
	String getDSLType();
	IMetaEnumeration getEnumeration();
}
