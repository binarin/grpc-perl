Grpc::XS::Call
new(const char *class,  Grpc::XS::Channel channel,  \
    const char* method, Grpc::XS::Timeval deadline, ... )
  PREINIT:
    CallCTX* ctx = (CallCTX *)malloc( sizeof(CallCTX) );
    ctx->wrapped = NULL;
  CODE:

    // Params:
    //    * channel       - channel object
    //    * method        - string
    //    * deadline      - timeval object
    //    * host_override - string (optional)

    if ( items > 5 ) {
      croak("Too many variables for constructor Grpc::XS::Call");
    }
#if defined(GRPC_VERSION_1_2)
    grpc_slice host_override;
    grpc_slice* host_override_ptr = NULL;

    if ( items == 5) {
      host_override = grpc_slice_from_sv(ST(4));
      host_override_ptr = &host_override;
    }

    grpc_slice method_slice = grpc_slice_from_static_string(method);
    ctx->wrapped = grpc_channel_create_call(
              channel->wrapped, NULL, GRPC_PROPAGATE_DEFAULTS, completion_queue,
              method_slice, host_override_ptr, deadline->wrapped, NULL);

    if (host_override_ptr) {
        grpc_slice_unref(host_override);
    }
    grpc_slice_unref(method_slice);
#else
    const char* host_override = NULL;
    if ( items == 5) {
      host_override = SvPV_nolen(ST(4));
    }

    ctx->wrapped = grpc_channel_create_call(
              channel->wrapped, NULL, GRPC_PROPAGATE_DEFAULTS, completion_queue,
              method, host_override, deadline->wrapped, NULL);
#endif

    RETVAL = ctx;
  OUTPUT: RETVAL

SV*
startBatch(Grpc::XS::Call self, ...)
  CODE:
    if ( items > 1 && ( items - 1 ) % 2 ) {
      croak("Expecting a hash as input to constructor");
    }

    /**
     * Start a batch of RPC actions.
     * @param array batch Array of actions to take
     * @return object Object with results of all actions
    */

    HV *result = newHV();
#if defined(GRPC_VERSION_1_2)
    grpc_slice send_status_details = grpc_empty_slice();
    grpc_slice recv_status_details = grpc_empty_slice();
#else
    char *status_details = NULL;
    size_t status_details_capacity = 0;
#endif
    grpc_op ops[8];

    size_t op_num = 0;

    grpc_byte_buffer *message;
    grpc_status_code status;
    grpc_call_error error;
    int cancelled;

    char *message_str;
    size_t message_len;

    grpc_metadata_array metadata;
    grpc_metadata_array trailing_metadata;
    grpc_metadata_array recv_metadata;
    grpc_metadata_array recv_trailing_metadata;

    grpc_metadata_array_init(&metadata);
    grpc_metadata_array_init(&trailing_metadata);
    grpc_metadata_array_init(&recv_metadata);
    grpc_metadata_array_init(&recv_trailing_metadata);

    if (items<2) goto cleanup;

    int i;
    for (i = 1; i < items; i += 2 ) {
      SV *key = ST(i);
      SV *value = ST(i+1);

      if (!looks_like_number(key)) {
        croak("Expected an int for message flags");
        goto cleanup;
      }

      switch(atoi(SvPV_nolen(key))) {
        case GRPC_OP_SEND_INITIAL_METADATA:
          value = SvRV(value);
          if (SvTYPE(value)!=SVt_PVHV) {
            croak("Expected a hash for GRPC_OP_SEND_INITIAL_METADATA");
            goto cleanup;
          }
          if (!create_metadata_array((HV*)value, &metadata)) {
            croak("Bad metadata value given");
            goto cleanup;
          }
          ops[op_num].data.send_initial_metadata.maybe_compression_level.is_set=0;
          ops[op_num].data.send_initial_metadata.count =
               metadata.count;
          ops[op_num].data.send_initial_metadata.metadata =
               metadata.metadata;
          break;
        case GRPC_OP_SEND_MESSAGE:
          value = SvRV(value);
          if (SvTYPE(value)!=SVt_PVHV) {
            croak("Expected a hash for send message");
            goto cleanup;
          }
          // ops[op_num].flags = hash->{flags} & GRPC_WRITE_USED_MASK;// int
          SV **flags = hv_fetchs((HV*)value, "flags", 0);
          if (flags) {
            if (!looks_like_number(*flags) || !SvIOK(*flags)) {
              croak("Expected an int for message flags");
              goto cleanup;
            }
            ops[op_num].flags = SvIV(*flags) & GRPC_WRITE_USED_MASK;
          }
          // ops[op_num].data.send_message = hash->{message}; // string
          SV **message_sv = hv_fetchs((HV*)value,"message",0);
          if (!message_sv) {
            croak("Missing send message");
            goto cleanup;
          }
          if (!SvOK(*message_sv)) {
            croak("Expected an string for send message");
            goto cleanup;
          }
          message_str = SvPV(*message_sv,message_len);
#if !defined(GRPC_VERSION_1_1)
          ops[op_num].data.send_message =
#else
          ops[op_num].data.send_message.send_message =
#endif
                      string_to_byte_buffer(message_str,message_len);
          break;
        case GRPC_OP_SEND_CLOSE_FROM_CLIENT:
          break;
        case GRPC_OP_SEND_STATUS_FROM_SERVER:
          if (SvROK(value)) value = SvRV(value);
          if (SvTYPE(value)!=SVt_PVHV) {
            croak("Expected a hash for send message");
            goto cleanup;
          }

          // hash->{metadata}
          if (hv_exists((HV*)value, "metadata", strlen("metadata"))) {
            SV** inner_value;
            inner_value = hv_fetchs((HV*)value, "metadata", 0);
            if (!create_metadata_array((HV*)SvRV(*inner_value), &trailing_metadata)) {
              croak("Bad trailing metadata value given");
              goto cleanup;
            }
            ops[op_num].data.send_status_from_server.trailing_metadata =
                trailing_metadata.metadata;
            ops[op_num].data.send_status_from_server.trailing_metadata_count =
                trailing_metadata.count;
          }
          // hash->{code}
          if (hv_exists((HV*)value, "code", strlen("code"))) {
            SV** inner_value;
            inner_value = hv_fetchs((HV*)value, "code", 0);
            if (!SvIOK(*inner_value)) {
              croak("Status code must be an integer");
              goto cleanup;
            }
            ops[op_num].data.send_status_from_server.status =
                                                    SvIV(*inner_value);
          } else {
            croak("Integer status code is required");
            goto cleanup;
          }
          // hash->{details}
          if (hv_exists((HV*)value, "details", strlen("details"))) {
            SV** inner_value;
            inner_value = hv_fetchs((HV*)value, "details", 0);
            if (!SvOK(*inner_value)) {
              croak("Status details must be a string");
              goto cleanup;
            }
#if defined(GRPC_VERSION_1_2)
            send_status_details = grpc_slice_from_sv(*inner_value);
            ops[op_num].data.send_status_from_server.status_details =
                &send_status_details;
#else
            ops[op_num].data.send_status_from_server.status_details =
                SvPV_nolen(*inner_value);
#endif
          } else {
            croak("String status details is required");
            goto cleanup;
          }
          break;
        case GRPC_OP_RECV_INITIAL_METADATA:
#if !defined(GRPC_VERSION_1_1)
          ops[op_num].data.recv_initial_metadata =
#else
          ops[op_num].data.recv_initial_metadata.recv_initial_metadata =
#endif
              &recv_metadata;
          break;
        case GRPC_OP_RECV_MESSAGE:
#if !defined(GRPC_VERSION_1_1)
          ops[op_num].data.recv_message =
#else
          ops[op_num].data.recv_message.recv_message =
#endif
              &message;
          break;
        case GRPC_OP_RECV_STATUS_ON_CLIENT:
#if defined GRPC_RECV_STATUS_ON_CLIENT_HAS_ERROR_STRING
          ops[op_num].data.recv_status_on_client.error_string = NULL;
#endif
          ops[op_num].data.recv_status_on_client.trailing_metadata =
              &recv_trailing_metadata;
          ops[op_num].data.recv_status_on_client.status = &status;
#if defined(GRPC_VERSION_1_2)
          ops[op_num].data.recv_status_on_client.status_details =
              &recv_status_details;
#else
          ops[op_num].data.recv_status_on_client.status_details =
              &status_details;
          ops[op_num].data.recv_status_on_client.status_details_capacity =
              &status_details_capacity;
#endif
          break;
        case GRPC_OP_RECV_CLOSE_ON_SERVER:
          ops[op_num].data.recv_close_on_server.cancelled = &cancelled;
          break;
        default:
          croak("Unrecognized key in batch");
          goto cleanup;
      }
      ops[op_num].op = (grpc_op_type)SvIV(key);
      ops[op_num].flags = 0;
      ops[op_num].reserved = NULL;
      op_num++;
    }

    error = grpc_call_start_batch(self->wrapped, ops, op_num, self->wrapped,
                                    NULL);

    if (error != GRPC_CALL_OK) {
      croak("start_batch was called incorrectly, error = %d",error);
      goto cleanup;
    }

    grpc_completion_queue_pluck(completion_queue, self->wrapped,
                                gpr_inf_future(GPR_CLOCK_REALTIME), NULL);

    for (i = 0; i < op_num; i++) {
      switch(ops[i].op) {
        case GRPC_OP_SEND_INITIAL_METADATA:
          hv_stores(result,"send_metadata",newSViv(TRUE));
          break;
        case GRPC_OP_SEND_MESSAGE:
          hv_stores(result,"send_message",newSViv(TRUE));
          break;
        case GRPC_OP_SEND_CLOSE_FROM_CLIENT:
          hv_stores(result,"send_close",newSViv(TRUE));
          break;
        case GRPC_OP_SEND_STATUS_FROM_SERVER:
          hv_stores(result,"send_status",newSViv(TRUE));
          break;
        case GRPC_OP_RECV_INITIAL_METADATA:
          hv_stores(result,"metadata",
               newRV_noinc((SV *)grpc_parse_metadata_array(&recv_metadata)));
          break;
        case GRPC_OP_RECV_MESSAGE:
          byte_buffer_to_string(message, &message_str, &message_len);
          if (message_str == NULL) {
            hv_stores(result,"message",newSV(0));//undef
          } else {
            hv_stores(result,"message",newSVpv(message_str,message_len));
          }
          break;
        case GRPC_OP_RECV_STATUS_ON_CLIENT: ;
          HV* recv_status = newHV();
          hv_stores(recv_status,"metadata",
              newRV_noinc((SV *)grpc_parse_metadata_array(&recv_trailing_metadata)));
          hv_stores(recv_status,"code",newSViv(status));
#if defined(GRPC_VERSION_1_2)
          hv_stores(recv_status, "details",
                        grpc_slice_to_sv(recv_status_details));
#else
          hv_stores(recv_status, "details",
                        newSVpv(status_details, 0));
#endif
          hv_stores(result,"status",newRV_noinc((SV *)recv_status));
          break;
        case GRPC_OP_RECV_CLOSE_ON_SERVER:
          hv_stores(result,"cancelled",newSViv(cancelled));
          break;
        default:
          break;
      }
    }

  cleanup:
    grpc_metadata_array_destroy(&metadata);
    grpc_metadata_array_destroy(&trailing_metadata);
    grpc_metadata_array_destroy(&recv_metadata);
    grpc_metadata_array_destroy(&recv_trailing_metadata);
#if defined(GRPC_VERSION_1_2)
    grpc_slice_unref(recv_status_details);
    grpc_slice_unref(send_status_details);
#else
    if (status_details != NULL) {
      gpr_free(status_details);
    }
#endif

    for (i = 0; i < op_num; i++) {
      if (ops[i].op == GRPC_OP_SEND_MESSAGE) {
#if !defined(GRPC_VERSION_1_1)
        grpc_byte_buffer_destroy(ops[i].data.send_message);
#else
        grpc_byte_buffer_destroy(ops[i].data.send_message.send_message);
#endif
      }
      if (ops[i].op == GRPC_OP_RECV_MESSAGE) {
        grpc_byte_buffer_destroy(message);
      }
    }
    RETVAL = (SV*)newRV_noinc((SV *)result);
  OUTPUT: RETVAL

const char*
getPeer(Grpc::XS::Call self)
  CODE:
    RETVAL = grpc_call_get_peer(self->wrapped);
  OUTPUT: RETVAL

void
cancel(Grpc::XS::Call self)
  CODE:
    grpc_call_cancel(self->wrapped, NULL);
  OUTPUT:

int
setCredentials(Grpc::XS::Call self, Grpc::XS::CallCredentials creds)
  CODE:
    int error = GRPC_CALL_ERROR;
    error = grpc_call_set_credentials(self->wrapped, creds->wrapped);
    RETVAL = error;
  OUTPUT: RETVAL

void
DESTROY(Grpc::XS::Call self)
  CODE:
    if (self->wrapped != NULL) {
#if defined(GRPC_VERSION_1_4)
      grpc_call_unref(self->wrapped);
#else
      grpc_call_destroy(self->wrapped);
#endif
    }
    Safefree(self);
