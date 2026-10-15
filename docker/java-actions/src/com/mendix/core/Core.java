package com.mendix.core;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.mendix.core.actionmanagement.MicroflowCallBuilder;
import com.mendix.core.conf.Configuration;
import com.mendix.datastorage.XPathQuery;
import com.mendix.logging.ILogNode;
import com.mendix.systemwideinterfaces.connectionbus.data.IDataTable;
import com.mendix.systemwideinterfaces.connectionbus.requests.IRetrievalSchema;
import com.mendix.systemwideinterfaces.connectionbus.requests.types.IGetRequest;
import com.mendix.systemwideinterfaces.connectionbus.requests.types.IOQLTextGetRequest;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IDataType;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;
import com.mendix.systemwideinterfaces.core.meta.IMetaObject;

import mxrb.sidecar.Bridge;
import mxrb.sidecar.Captions;
import mxrb.sidecar.Metadata;
import mxrb.sidecar.MxDataTable;
import mxrb.sidecar.MxDataType;
import mxrb.sidecar.MxOqlRequest;
import mxrb.sidecar.MxContext;
import mxrb.sidecar.MxLogNode;
import mxrb.sidecar.MxMicroflowCall;
import mxrb.sidecar.MxXPathQuery;

/** The Runtime API of the Ruby application, reached through the invocation's bridge. */
public final class Core {
	private Core() {
	}

	public static ILogNode getLogger(String name) {
		return new MxLogNode(name);
	}

	public static IMendixObject instantiate(IContext context, String entity) {
		return (IMendixObject) bridge(context).call("instantiate", "entity", entity);
	}

	public static IMendixObject commit(IContext context, IMendixObject object) throws CoreException {
		store(context, "commit", List.of(object), true);
		return object;
	}

	public static List<IMendixObject> commit(IContext context, List<IMendixObject> objects) {
		store(context, "commit", objects, true);
		return objects;
	}

	public static IMendixObject commitWithoutEvents(IContext context, IMendixObject object) {
		store(context, "commit", List.of(object), false);
		return object;
	}

	public static List<IMendixObject> commitWithoutEvents(IContext context, List<IMendixObject> objects) {
		store(context, "commit", objects, false);
		return objects;
	}

	public static boolean delete(IContext context, IMendixObject... objects) {
		store(context, "delete", Arrays.asList(objects), true);
		return true;
	}

	public static boolean delete(IContext context, List<IMendixObject> objects) {
		store(context, "delete", objects, true);
		return true;
	}

	public static boolean delete(IContext context, List<IMendixObject> objects, boolean useDeleteBehavior) {
		return delete(context, objects);
	}

	public static boolean deleteWithoutEvents(IContext context, List<IMendixObject> objects, boolean useDeleteBehavior) {
		store(context, "delete", objects, false);
		return true;
	}

	public static IMendixObject rollback(IContext context, IMendixObject object) throws CoreException {
		store(context, "rollback", List.of(object), true);
		return object;
	}

	public static IMendixObject retrieveId(IContext context, IMendixIdentifier id) throws CoreException {
		return id == null ? null : id.getObject();
	}

	public static List<IMendixObject> retrieveIdList(IContext context, List<IMendixIdentifier> ids) throws CoreException {
		List<IMendixObject> objects = new ArrayList<>();
		for (IMendixIdentifier id : ids) {
			objects.add(retrieveId(context, id));
		}
		return objects;
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath) throws CoreException {
		return createXPathQuery(xpath).execute(context);
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath, int amount, int offset,
			Map<String, String> sort) throws CoreException {
		return retrieveXPathQuery(context, xpath, amount, offset, sort, 0);
	}

	public static List<IMendixObject> retrieveXPathQuery(IContext context, String xpath, int amount, int offset,
			Map<String, String> sort, int depth) throws CoreException {
		XPathQuery query = createXPathQuery(xpath).setAmount(amount).setOffset(offset);
		sort.forEach((path, order) -> query.addSort(path, !"desc".equalsIgnoreCase(order)));
		return query.execute(context);
	}

	public static XPathQuery createXPathQuery(String xpath) {
		return new MxXPathQuery(xpath);
	}

	@SuppressWarnings("unchecked")
	public static List<IMendixObject> retrieveByPath(IContext context, IMendixObject object, String path) {
		return (List<IMendixObject>) bridge(context).call("related", "object", object, "association", path);
	}

	public static List<IMendixObject> retrieveByPath(IContext context, IMendixObject object, String path,
			boolean isSelfAssociationChild) {
		return retrieveByPath(context, object, path);
	}

	public static MicroflowCallBuilder microflowCall(String name) {
		return new MxMicroflowCall(name);
	}

	public static <R> R execute(IContext context, String microflow, Map<String, Object> parameters)
			throws CoreException {
		return microflowCall(microflow).withParams(parameters).execute(context);
	}

	/** COUNT, SUM, AVG, MIN or MAX of an XPath query, such as "COUNT(//Module.Entity[...])" or "SUM(//Module.Entity/Total)". */
	public static Long retrieveXPathQueryAggregate(IContext context, String aggregate) throws CoreException {
		java.math.BigDecimal result = mxrb.sidecar.Aggregate.compute(context, aggregate, Map.of());
		return result == null ? null : result.setScale(0, java.math.RoundingMode.HALF_UP).longValue();
	}

	public static String getInternationalizedString(String languageCode, String key, Object... arguments) {
		return format(Captions.caption(languageCode, key), arguments);
	}

	public static String getInternationalizedString(IContext context, String key, Object... arguments) {
		return format(Captions.caption(null, key), arguments);
	}

	public static IMetaObject getMetaObject(String entity) {
		return Metadata.get().object(entity);
	}

	public static Iterable<IMetaObject> getMetaObjects() {
		return new ArrayList<>(Metadata.get().objects());
	}

	public static IMetaAssociation getMetaAssociation(String association) {
		return Metadata.get().association(association);
	}

	public static Iterable<IMetaAssociation> getMetaAssociations() {
		return new ArrayList<>(Metadata.get().associations());
	}

	public static List<String> getSubtypesOf(String entity) {
		List<String> subtypes = new ArrayList<>();
		IMetaObject object = getMetaObject(entity);
		if (object != null) {
			object.getSubObjects().forEach(sub -> subtypes.add(sub.getName()));
		}
		return subtypes;
	}

	public static Set<String> getMicroflowNames() {
		return new LinkedHashSet<>(Metadata.get().microflowNames());
	}

	public static Map<String, IDataType> getInputParameters(String microflow) {
		return Metadata.get().parameters(microflow);
	}

	public static IDataType getReturnType(String microflow) {
		return Metadata.get().returnType(microflow);
	}

	public static IDataType createDataType(String type) {
		return MxDataType.parse(Metadata.get(), type);
	}

	/** The type of an entity's attribute. */
	public static IDataType createDataType(String entity, String attribute) {
		IMetaObject object = getMetaObject(entity);
		if (object == null || object.getMetaPrimitive(attribute) == null) {
			throw new IllegalArgumentException("unknown attribute " + entity + "." + attribute);
		}
		return createDataType(object.getMetaPrimitive(attribute).getType().name());
	}

	public static boolean isSubClassOf(String superClass, String type) {
		IMetaObject object = getMetaObject(type);
		return object != null && object.isSubClassOf(superClass);
	}

	public static boolean isSubClassOf(IMetaObject superClass, IMetaObject type) {
		return type.isSubClassOf(superClass);
	}

	/** The locale of the calling user; the Ruby application formats for en_US. */
	public static java.util.Locale getLocale(IContext context) {
		return java.util.Locale.US;
	}

	public static InputStream getFileDocumentContent(IContext context, IMendixObject file) {
		return new ByteArrayInputStream((byte[]) bridge(context).call("file", "object", file));
	}

	public static void storeFileDocumentContent(IContext context, IMendixObject file, InputStream content) {
		Object name = file.getValue(context, "Name");
		storeFileDocumentContent(context, file, name == null ? "file" : name.toString(), content);
	}

	public static void storeFileDocumentContent(IContext context, IMendixObject file, String name,
			InputStream content) {
		try {
			bridge(context).call("store_file", "object", file, "name", name, "content", content.readAllBytes());
		} catch (IOException e) {
			throw new UncheckedIOException(e);
		}
	}

	/** An image's contents; the Ruby application serves thumbnails itself. */
	public static InputStream getImage(IContext context, IMendixObject image, boolean thumbnail) {
		return getFileDocumentContent(context, image);
	}

	/** The user with a name, or null. */
	public static com.mendix.systemwideinterfaces.core.IUser getUser(IContext context, String name) throws CoreException {
		List<IMendixObject> users = createXPathQuery("//System.User[Name = $name]").setVariable("name", name)
				.setAmount(1).execute(context);
		if (users.isEmpty()) {
			return null;
		}
		IMendixObject user = users.get(0);
		return new com.mendix.systemwideinterfaces.core.IUser() {
			@Override
			public String getName() {
				return user.getValue(context, "Name");
			}

			@Override
			public IMendixObject getMendixObject() {
				return user;
			}
		};
	}

	public static IOQLTextGetRequest createOQLTextGetRequest() {
		return new MxOqlRequest(null);
	}

	/** A request for a dataset's OQL, by the dataset's name. */
	public static IOQLTextGetRequest createOQLTextGetRequestFromDataSet(String dataset) {
		return new MxOqlRequest(dataset);
	}

	public static IRetrievalSchema createRetrievalSchema() {
		return new MxOqlRequest.Range();
	}

	public static IDataTable retrieveOQLDataTable(IContext context, String query) throws CoreException {
		return retrieveOQLDataTable(context, new MxOqlRequest(query));
	}

	public static IDataTable retrieveOQLDataTable(IContext context, String query, int amount, int offset)
			throws CoreException {
		MxOqlRequest request = new MxOqlRequest(query);
		request.getRetrievalSchema().setAmount(amount);
		request.getRetrievalSchema().setOffset(offset);
		return retrieveOQLDataTable(context, request);
	}

	@SuppressWarnings("unchecked")
	public static IDataTable retrieveOQLDataTable(IContext context, IGetRequest request) throws CoreException {
		if (!(request instanceof MxOqlRequest oql)) {
			throw new CoreException("unsupported request " + request.getClass().getName());
		}
		IRetrievalSchema range = oql.getRetrievalSchema();
		return new MxDataTable((Map<String, Object>) bridge(context).call("oql", "query", oql.getQuery(), "parameters",
				oql.values(), "offset", range.getOffset(), "amount", range.getAmount()));
	}

	/** An image's contents; the Ruby application makes its thumbnails itself. */
	public static void storeImageDocumentContent(IContext context, IMendixObject image, InputStream content,
			int thumbnailWidth, int thumbnailHeight) {
		storeFileDocumentContent(context, image, content);
	}

	/** Registers a handler for the requests to a path; the Ruby application's server forwards them. */
	public static void addRequestHandler(String path, com.mendix.externalinterface.connector.RequestHandler handler) {
		mxrb.sidecar.Handlers.register(path, handler);
		Bridge.current().call("request_handler", "path", mxrb.sidecar.Handlers.key(path));
	}

	/** A new guest session, whose cookie a request handler sets on its response. */
	@SuppressWarnings("unchecked")
	public static com.mendix.systemwideinterfaces.core.ISession initializeGuestSession() {
		Bridge bridge = Bridge.current();
		return mxrb.sidecar.MxSession.of(bridge, (Map<String, Object>) bridge.call("guest_session"));
	}

	/** The Ruby application's sessions stay in its server; a Java action sees none of another user's. */
	public static com.mendix.systemwideinterfaces.core.ISession getActiveSession(String userName) {
		return null;
	}

	/**
	 * A session for a user, whose contexts run microflows as that user, as
	 * CommunityCommons executes a microflow as another user.
	 */
	public static com.mendix.systemwideinterfaces.core.ISession initializeSession(
			com.mendix.systemwideinterfaces.core.IUser user, String currentSessionId) {
		Map<String, Object> session = new java.util.LinkedHashMap<>();
		session.put("id", java.util.UUID.randomUUID().toString());
		session.put("user", user.getMendixObject());
		session.put("name", user.getName());
		session.put("anonymous", Boolean.FALSE);
		return mxrb.sidecar.MxSession.of(Bridge.current(), session);
	}

	/** The cluster node id cookie a request handler may set; the Ruby application has one node. */
	public static String getXASId() {
		return "mxrb";
	}

	/** The object behind a number IMendixIdentifier.toLong gave. */
	public static IMendixIdentifier createMendixIdentifier(long id) {
		IMendixObject object = (IMendixObject) Bridge.current().call("object_for_long", "id", id);
		return object == null ? null : object.getId();
	}

	public static IMendixIdentifier createMendixIdentifier(Long id) {
		return id == null ? null : createMendixIdentifier(id.longValue());
	}

	/**
	 * A microflow run for a Java action that would run it in the background: the
	 * sidecar runs it before returning, in the calling transaction, and hands back
	 * its finished result.
	 */
	public static <R> java.util.concurrent.Future<R> executeAsync(IContext context, String microflow,
			boolean executeQueued, Map<String, Object> parameters) throws CoreException {
		R result = microflowCall(microflow).withParams(parameters).execute(context);
		return java.util.concurrent.CompletableFuture.completedFuture(result);
	}

	/**
	 * The positional form: the arguments go to the microflow's parameters, which
	 * works for a microflow of one parameter; others need the named form.
	 */
	public static <R> java.util.concurrent.Future<R> executeAsync(IContext context, String microflow,
			boolean executeQueued, Object... arguments) throws CoreException {
		Map<String, IDataType> parameters = getInputParameters(microflow);
		if (parameters == null || parameters.size() != arguments.length || arguments.length > 1) {
			throw new CoreException("pass the arguments of " + microflow + " by name");
		}
		Map<String, Object> named = new java.util.LinkedHashMap<>();
		if (arguments.length == 1) {
			named.put(parameters.keySet().iterator().next(), arguments[0]);
		}
		return executeAsync(context, microflow, executeQueued, named);
	}

	/** The project's default language. */
	@SuppressWarnings("unchecked")
	public static com.mendix.systemwideinterfaces.core.ILanguage getDefaultLanguage() {
		Map<String, Object> language = (Map<String, Object>) Bridge.current().call("default_language");
		return new com.mendix.systemwideinterfaces.core.ILanguage() {
			@Override
			public String getCode() {
				return (String) language.get("code");
			}

			@Override
			public IMendixObject getMendixObject() {
				return (IMendixObject) language.get("language");
			}
		};
	}

	/** The Ruby application keeps the log, so a subscriber in the sidecar receives no messages. */
	public static void registerLogSubscriber(com.mendix.logging.LogSubscriber subscriber) {
	}

	/** Whether a password is a user's, as signing in checks it. */
	public static boolean authenticate(IContext context, com.mendix.systemwideinterfaces.core.IUser user,
			String password) throws CoreException {
		return Boolean.TRUE.equals(bridge(context).call("authenticate", "user", user.getName(), "password", password));
	}

	/** The language of the context's user (System.User_Language), else the project's default. */
	public static com.mendix.systemwideinterfaces.core.ILanguage getLanguage(IContext context) {
		IMendixObject user = context.getCurrentUserObject();
		IMendixIdentifier language = user == null ? null : user.getValue(context, "System.User_Language");
		if (language == null) {
			return getDefaultLanguage();
		}
		IMendixObject object = language.getObject();
		return new com.mendix.systemwideinterfaces.core.ILanguage() {
			@Override
			public String getCode() {
				return object.getValue(context, "Code");
			}

			@Override
			public IMendixObject getMendixObject() {
				return object;
			}
		};
	}

	/** The application's metrics; the sidecar records none. */
	public static com.mendix.metrics.Metrics metrics() {
		return com.mendix.metrics.Metrics.none();
	}

	public static IContext createSystemContext() {
		return new MxContext(Bridge.current(), true);
	}

	public static Configuration getConfiguration() {
		Bridge bridge = Bridge.current();
		return new Configuration() {
			@Override
			public String getApplicationRootUrl() {
				return (String) bridge.call("application_root_url");
			}

			@Override
			public Object getConstantValue(String name) {
				return bridge.call("constant", "name", name);
			}
		};
	}

	public static String getRuntimeVersion() {
		return (String) Bridge.current().call("runtime_version");
	}

	public static String getModelVersion() {
		return (String) Bridge.current().call("model_version");
	}

	private static String format(String text, Object... arguments) {
		String result = text;
		for (int i = 0; arguments != null && i < arguments.length; i++) {
			result = result.replace("{" + (i + 1) + "}", String.valueOf(arguments[i]));
		}
		return result;
	}

	private static Bridge bridge(IContext context) {
		return ((MxContext) context).bridge();
	}

	private static void store(IContext context, String method, List<IMendixObject> objects, boolean events) {
		bridge(context).call(method, "objects", objects, "events", events);
	}
}
