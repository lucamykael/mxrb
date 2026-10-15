package com.mendix.datastorage;

import java.math.BigDecimal;
import java.util.Date;
import java.util.List;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** An XPath retrieve with variables, a range and sortings. */
public interface XPathQuery {
	XPathQuery setAmount(int amount);
	XPathQuery setOffset(int offset);
	XPathQuery addSort(String path, boolean ascending);
	XPathQuery setDepth(int depth);
	XPathQuery setVariable(String name, BigDecimal value);
	XPathQuery setVariable(String name, boolean value);
	XPathQuery setVariable(String name, double value);
	XPathQuery setVariable(String name, int value);
	XPathQuery setVariable(String name, long value);
	XPathQuery setVariable(String name, IMendixObject value);
	XPathQuery setVariable(String name, IMendixIdentifier value);
	XPathQuery setVariable(String name, String value);
	XPathQuery setVariable(String name, Date value);
	List<IMendixObject> execute(IContext context);
}
